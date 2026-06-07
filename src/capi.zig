const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const is_freestanding = builtin.os.tag == .freestanding;

// Freestanding targets do not have a known page size; Zig's std.heap refuses
// to analyze without one. Pick 4 KiB to match QEMU `virt` and the OpenSBI
// handoff convention for riscv64. Hosted targets must keep the OS-derived
// default -- macOS aarch64 uses 16 KiB pages, and forcing 4 KiB misaligns
// page-aligned allocations and crashes AOT-linked binaries.
pub const std_options: std.Options = .{
    .page_size_min = if (is_freestanding) 4096 else null,
};

// The default panic handler reaches into std.Thread for stderr locking,
// which has no implementation on freestanding. On freestanding, install
// a minimal trap-based handler; on hosted, mirror Zig's stock default so
// AOT runtime semantics are unchanged.
pub const panic = if (is_freestanding)
    std.debug.no_panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

const context_mod = @import("context.zig");
const Context = context_mod.Context;

const statement_mod = @import("statement.zig");
const StatementProcessor = statement_mod.StatementProcessor;

const effect_inference = @import("effect_inference.zig");
const call_graph = @import("call_graph.zig");

const errors_mod = @import("primitives/errors.zig");
const pascalToKebabRuntime = errors_mod.pascalToKebabRuntime;

const misc = @import("primitives/misc.zig");
const dictionary_mod = @import("dictionary.zig");
const HostCallback = dictionary_mod.HostCallback;
const HostCallbackFn = dictionary_mod.HostCallbackFn;

const helpers = @import("primitives/helpers.zig");
const bail_stats_mod = @import("bail_stats.zig");
const StackEffect = @import("stack_effect.zig").StackEffect;

const dispatch_mod = @import("dispatch.zig");
const DispatchKey = dispatch_mod.DispatchKey;
const DispatchEntry = dispatch_mod.DispatchEntry;

const value_mod = @import("value.zig");
const MutableMap = value_mod.MutableMap;
const Value = value_mod.Value;
const TypeValue = value_mod.TypeValue;

const debugger_mod = @import("debugger/mod.zig");

const aot_image_loader = @import("aot_image_loader.zig");

const HostWordRegistration = struct {
    name: []const u8,
};

/// Handle-owned snapshot of an InferenceEngine diagnostic. The engine frees
/// `message` in its `deinit`, and `word_name`/`source_file` are borrowed
/// references into the dictionary and source arena; copying all three gives
/// a single lifetime contract for `onez_diag_*` callers: each pointer is
/// valid until the next `onez_check` call on the same handle.
const OwnedDiagnostic = struct {
    severity: effect_inference.Severity,
    message: [:0]const u8,
    source_file: ?[:0]const u8,
    source_line: usize,
    word_name: [:0]const u8,
};

// Freestanding builds have no page allocator and no GeneralPurposeAllocator
// backed by the OS. The runtime carves all dynamic allocations out of a
// statically reserved region whose size is fixed at build time via the
// `freestanding-heap-mib` build option. Running out of this region throws a
// 1z-level OutOfMemory just like a hosted heap exhaustion would.
const HostGpa = if (is_freestanding) std.heap.FixedBufferAllocator else std.heap.GeneralPurposeAllocator(.{});

const freestanding_heap_size: usize = @as(usize, build_options.freestanding_heap_mib) << 20;
var freestanding_heap_buf: [if (is_freestanding) freestanding_heap_size else 0]u8 align(16) = undefined;
var freestanding_root_fba: std.heap.FixedBufferAllocator = undefined;
var freestanding_root_inited: bool = false;

fn rootAllocator() std.mem.Allocator {
    if (is_freestanding) {
        if (!freestanding_root_inited) {
            freestanding_root_fba = std.heap.FixedBufferAllocator.init(&freestanding_heap_buf);
            freestanding_root_inited = true;
        }
        return freestanding_root_fba.allocator();
    } else {
        return std.heap.page_allocator;
    }
}

const OnezHandle = struct {
    gpa: *HostGpa,
    ctx: *Context,
    last_error: ?[:0]const u8 = null,
    host_words: std.ArrayListUnmanaged(HostWordRegistration) = .{},
    saved_obligation_frames: std.ArrayListUnmanaged(
        std.ArrayListUnmanaged(context_mod.ProtocolObligation),
    ) = .{},
    diagnostics: std.ArrayListUnmanaged(OwnedDiagnostic) = .{},

    /// Heap-allocated debugger, created by onez_debug_enable. Persists across
    /// enable/disable cycles so breakpoints and callbacks survive re-enable.
    debugger: ?*debugger_mod.Debugger = null,

    /// Stored C debug callback and userdata, wired into the debugger's
    /// EventEmitter when the debugger is active.
    debug_callback: ?OnezDebugCallbackFn = null,
    debug_userdata: ?*anyopaque = null,
};

// Type constants for onez_stack_type return values.
pub const ONEZ_TYPE_UNKNOWN: c_int = 0;
pub const ONEZ_TYPE_FIXNUM: c_int = 1;
pub const ONEZ_TYPE_FLOAT: c_int = 2;
pub const ONEZ_TYPE_BOOLEAN: c_int = 3;
pub const ONEZ_TYPE_STRING: c_int = 4;
pub const ONEZ_TYPE_SYMBOL: c_int = 5;
pub const ONEZ_TYPE_ARRAY: c_int = 6;
pub const ONEZ_TYPE_QUOTATION: c_int = 7;
pub const ONEZ_TYPE_HASH: c_int = 8;
pub const ONEZ_TYPE_VECTOR: c_int = 9;
pub const ONEZ_TYPE_BYTE_ARRAY: c_int = 10;
pub const ONEZ_TYPE_SET: c_int = 11;
pub const ONEZ_TYPE_MUTABLE_MAP: c_int = 12;
pub const ONEZ_TYPE_STREAM: c_int = 13;
pub const ONEZ_TYPE_RESOURCE: c_int = 14;
pub const ONEZ_TYPE_TAGGED: c_int = 15;
pub const ONEZ_TYPE_ITERATOR: c_int = 16;
pub const ONEZ_TYPE_TYPE_VAL: c_int = 17;
pub const ONEZ_TYPE_UNIT: c_int = 18;
pub const ONEZ_TYPE_STRUCT: c_int = 19;

// Error code constants.
pub const ONEZ_OK: c_int = 0;
pub const ONEZ_ERR_NULL_HANDLE: c_int = -1;
pub const ONEZ_ERR_TYPE_MISMATCH: c_int = 1;
pub const ONEZ_ERR_STACK_UNDERFLOW: c_int = 2;
pub const ONEZ_ERR_ALLOC: c_int = 3;
pub const ONEZ_ERR_NULL_VALUE: c_int = -2;
pub const ONEZ_ERR_INDEX_OUT_OF_RANGE: c_int = 4;
pub const ONEZ_ERR_KEY_NOT_FOUND: c_int = 5;
pub const ONEZ_ERR_LOAD_FAILED: c_int = 6;
pub const ONEZ_ERR_NOT_HOST_WORD: c_int = 7;
pub const ONEZ_ERR_INVALID_EFFECT: c_int = 8;
pub const ONEZ_ERR_WORD_NOT_FOUND: c_int = 9;
pub const ONEZ_ERR_ISOLATION_UNDERFLOW: c_int = 10;
pub const ONEZ_ERR_DEBUGGER_NOT_ACTIVE: c_int = 11;
pub const ONEZ_ERR_BREAKPOINT_NOT_FOUND: c_int = 12;

// Debug event constants for onez_debug_set_callback.
pub const ONEZ_EVENT_PAUSED: c_int = 0;
pub const ONEZ_EVENT_RESUMED: c_int = 1;
pub const ONEZ_EVENT_BREAKPOINT_HIT: c_int = 2;
pub const ONEZ_EVENT_STEP_COMPLETED: c_int = 3;

// Debug callback function type.
pub const OnezDebugCallbackFn = *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) void;

// Diagnostic severity constants returned by onez_diag_severity.
// These match @intFromEnum of effect_inference.Severity by declaration order.
pub const ONEZ_DIAG_ERROR: c_int = 0;
pub const ONEZ_DIAG_WARNING: c_int = 1;
pub const ONEZ_DIAG_NOTE: c_int = 2;

comptime {
    std.debug.assert(@intFromEnum(effect_inference.Severity.err) == ONEZ_DIAG_ERROR);
    std.debug.assert(@intFromEnum(effect_inference.Severity.warning) == ONEZ_DIAG_WARNING);
    std.debug.assert(@intFromEnum(effect_inference.Severity.note) == ONEZ_DIAG_NOTE);
}

/// Initialize the 1z runtime with primitives only; no prelude is loaded.
///
/// Call onez_load_prelude() afterwards to load the default or a custom
/// prelude, or skip the prelude entirely for bare-metal embedding.
export fn onez_init_no_prelude() ?*anyopaque {
    const gpa = createGpa() orelse return null;
    const allocator = gpa.allocator();

    const ctx = allocator.create(Context) catch return null;
    ctx.* = Context.init(allocator);

    // Freestanding builds have no filesystem to discover the stdlib from;
    // ctx.stdlib_path stays null and any `use` of a stdlib module relies on
    // the embedded fallback (or fails fast).
    if (!is_freestanding) {
        var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
            const lib_path = std.fs.path.join(ctx.quotationAllocator(), &.{ exe_dir, "../lib" }) catch null;
            if (lib_path) |lp| {
                var real_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fs.cwd().realpath(lp, &real_buf)) |real| {
                    ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, real) catch null;
                } else |_| {}
            }
        } else |_| {}
    }

    const handle_alloc = if (is_freestanding) allocator else std.heap.page_allocator;
    const handle = handle_alloc.create(OnezHandle) catch return null;
    handle.* = .{
        .gpa = gpa,
        .ctx = ctx,
    };
    return handle;
}

fn createGpa() ?*HostGpa {
    if (is_freestanding) {
        if (!freestanding_root_inited) {
            freestanding_root_fba = std.heap.FixedBufferAllocator.init(&freestanding_heap_buf);
            freestanding_root_inited = true;
        }
        return &freestanding_root_fba;
    } else {
        const gpa = std.heap.page_allocator.create(HostGpa) catch return null;
        gpa.* = .{};
        return gpa;
    }
}

/// Initialize the 1z runtime and load the default embedded prelude.
///
/// Equivalent to onez_init_no_prelude() followed by
/// onez_load_prelude(handle, NULL).
export fn onez_init() ?*anyopaque {
    const handle = onez_init_no_prelude() orelse return null;
    if (onez_load_prelude(handle, null) != ONEZ_OK) {
        onez_deinit(handle);
        return null;
    }
    return handle;
}

export fn onez_deinit(ptr: ?*anyopaque) void {
    bail_stats_mod.deinitGlobal();

    const handle = castHandle(ptr) orelse return;
    const allocator = handle.gpa.allocator();

    clearLastError(handle);
    clearDiagnostics(handle);
    handle.diagnostics.deinit(allocator);

    if (handle.debugger) |dbg| {
        handle.ctx.debugger = null;
        dbg.deinit();
        allocator.destroy(dbg);
        handle.debugger = null;
    }

    for (handle.host_words.items) |entry| {
        allocator.free(entry.name);
    }
    handle.host_words.deinit(allocator);

    // XXX(ripta): forcefully close any unclosed isolation frames to avoid leaks. This
    //             is a bit hacky but it avoids the need for a more complex ownership
    //             model for obligation frames.
    for (handle.saved_obligation_frames.items) |*frame| {
        frame.deinit(handle.ctx.allocator);
    }
    handle.saved_obligation_frames.deinit(allocator);

    if (handle.ctx.program_args.len > 0) {
        allocator.free(handle.ctx.program_args);
        handle.ctx.program_args = &.{};
    }

    handle.ctx.deinit();
    if (is_freestanding) {
        // The static FBA-backed heap is never freed; the bare-metal program
        // either runs to completion or hangs. Nothing to tear down beyond the
        // ctx-level deinit above.
        return;
    }
    allocator.destroy(handle.ctx);
    _ = handle.gpa.deinit();
    std.heap.page_allocator.destroy(handle.gpa);
    std.heap.page_allocator.destroy(handle);
}

/// Load a prelude into a context.
///
/// If path is null, the default embedded prelude is loaded. If path is
/// non-null, the file at the given null-terminated path is read and used
/// as the prelude source.
export fn onez_load_prelude(ptr: ?*anyopaque, path: ?[*:0]const u8) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;

    ctx.clearExecutionDetails();
    clearLastError(handle);

    if (path) |p| {
        if (is_freestanding) {
            setLastError(handle, "file-based prelude loading is not available on this build", .{});
            return ONEZ_ERR_LOAD_FAILED;
        }
        const filepath = std.mem.span(p);
        const alloc = ctx.quotationAllocator();

        const file = std.fs.cwd().openFile(filepath, .{}) catch {
            setLastError(handle, "failed to open prelude file: {s}", .{filepath});
            return ONEZ_ERR_LOAD_FAILED;
        };
        defer file.close();

        const source = file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch {
            setLastError(handle, "failed to read prelude file: {s}", .{filepath});
            return ONEZ_ERR_LOAD_FAILED;
        };

        ctx.loadPrelude(source) catch |err| {
            captureError(handle, err);
            return ONEZ_ERR_LOAD_FAILED;
        };
    } else {
        ctx.loadPrelude(null) catch |err| {
            captureError(handle, err);
            return ONEZ_ERR_LOAD_FAILED;
        };
    }

    return ONEZ_OK;
}

/// Load the AOT runtime image after the prelude is in place. The
/// generated `main()` for runtime-image AOT binaries calls this once
/// between `onez_init` and `onez_set_args`.
///
/// `header_ptr` points at the embedded `onez_image_v1` symbol; the
/// six slot-table pointers point at the first element of the
/// corresponding `onez_image_*_slots[]` arrays. All pointers must
/// remain valid for the lifetime of the runtime. Any slot-table
/// pointer may be NULL when its table was not emitted (zero slots).
export fn onez_load_runtime_image(
    ptr: ?*anyopaque,
    header_ptr: ?*const anyopaque,
    typevalue_slots_ptr: ?*anyopaque,
    struct_type_slots_ptr: ?*anyopaque,
    marker_slots_ptr: ?*anyopaque,
    parameter_slots_ptr: ?*anyopaque,
    tagged_slots_ptr: ?*anyopaque,
    mutable_map_slots_ptr: ?*anyopaque,
) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;

    const hp = header_ptr orelse {
        setLastError(handle, "onez_load_runtime_image: NULL header pointer", .{});
        return ONEZ_ERR_LOAD_FAILED;
    };
    const header: *const aot_image_loader.Header = @ptrCast(@alignCast(hp));

    const typevalue_slots: ?aot_image_loader.SlotTable = if (typevalue_slots_ptr) |sp|
        @ptrCast(@alignCast(sp))
    else
        null;
    const struct_type_slots: ?aot_image_loader.StructTypeSlotTable = if (struct_type_slots_ptr) |sp|
        @ptrCast(@alignCast(sp))
    else
        null;
    const marker_slots: ?aot_image_loader.MarkerSlotTable = if (marker_slots_ptr) |sp|
        @ptrCast(@alignCast(sp))
    else
        null;
    const parameter_slots: ?aot_image_loader.ParameterSlotTable = if (parameter_slots_ptr) |sp|
        @ptrCast(@alignCast(sp))
    else
        null;
    const tagged_slots: ?aot_image_loader.TaggedSlotTable = if (tagged_slots_ptr) |sp|
        @ptrCast(@alignCast(sp))
    else
        null;
    const mutable_map_slots: ?aot_image_loader.MutableMapSlotTable = if (mutable_map_slots_ptr) |sp|
        @ptrCast(@alignCast(sp))
    else
        null;

    aot_image_loader.loadIntoContext(ctx, header, .{
        .typevalues = typevalue_slots,
        .struct_types = struct_type_slots,
        .markers = marker_slots,
        .parameters = parameter_slots,
        .tagged = tagged_slots,
        .mutable_maps = mutable_map_slots,
    }, null) catch |err| {
        captureError(handle, err);
        return ONEZ_ERR_LOAD_FAILED;
    };
    return ONEZ_OK;
}

export fn onez_eval(ptr: ?*anyopaque, code: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();
    const source = code[0..len];

    ctx.clearExecutionDetails();
    clearLastError(handle);

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        start = end + 1;

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                captureError(handle, err);
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        captureError(handle, err);
                        return 1;
                    };
                }
                processor.reset();
            },
        }
    }

    switch (processor.flush(alloc, ctx)) {
        .needs_more_input => {},
        .parse_error => |err| {
            captureError(handle, err);
            return 1;
        },
        .complete => |instrs| {
            if (instrs.len > 0) {
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                    captureError(handle, err);
                    return 1;
                };
            }
        },
    }

    return ONEZ_OK;
}

/// Evaluate a .1z file by path. The null-terminated path is opened, read
/// line-by-line, and executed as if passed to onez_eval. No module is
/// created; definitions become visible in the current scope.
export fn onez_eval_file(ptr: ?*anyopaque, path: ?[*:0]const u8) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();

    ctx.clearExecutionDetails();
    clearLastError(handle);

    if (is_freestanding) {
        setLastError(handle, "onez_eval_file is not available on this build", .{});
        return ONEZ_ERR_LOAD_FAILED;
    }

    const filepath = std.mem.span(path orelse {
        setLastError(handle, "null path passed to onez_eval_file", .{});
        return ONEZ_ERR_NULL_HANDLE;
    });

    const file = std.fs.cwd().openFile(filepath, .{}) catch {
        setLastError(handle, "file not found: {s}", .{filepath});
        return ONEZ_ERR_LOAD_FAILED;
    };
    defer file.close();

    const old_source = ctx.current_source;
    ctx.current_source = filepath;
    defer ctx.current_source = old_source;

    const old_source_dir = ctx.current_source_dir;
    ctx.current_source_dir = std.fs.path.dirname(filepath);
    defer ctx.current_source_dir = old_source_dir;

    var file_buf: [4096]u8 = undefined;
    var reader = file.reader(&file_buf);

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                switch (processor.flush(alloc, ctx)) {
                    .needs_more_input => {},
                    .parse_error => |e| {
                        captureError(handle, e);
                        return 1;
                    },
                    .complete => |instrs| {
                        if (instrs.len > 0) {
                            ctx.executeQuotation(.{ .instructions = instrs }) catch |e2| {
                                captureError(handle, e2);
                                return 1;
                            };
                        }
                    },
                }
                break;
            },
            else => {
                setLastError(handle, "failed to read file: {s}", .{filepath});
                return ONEZ_ERR_LOAD_FAILED;
            },
        };

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                captureError(handle, err);
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        captureError(handle, err);
                        return 1;
                    };
                }
                processor.reset();
            },
        }
    }

    return ONEZ_OK;
}

/// Push an isolation frame. Type registrations, dispatch entries, and
/// protocol obligations created after this call are scoped: they will
/// be discarded when onez_isolation_end is called. Stack values are
/// not affected.
export fn onez_isolation_begin(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;

    clearLastError(handle);

    ctx.pushTypeRegistryFrame() catch {
        setLastError(handle, "isolation begin: type registry frame alloc failed", .{});
        return ONEZ_ERR_ALLOC;
    };

    ctx.pushDispatchFrame() catch {
        ctx.popTypeRegistryFrame();
        setLastError(handle, "isolation begin: dispatch frame alloc failed", .{});
        return ONEZ_ERR_ALLOC;
    };

    handle.saved_obligation_frames.append(handle.gpa.allocator(), ctx.protocol_obligations) catch {
        ctx.popDispatchFrame();
        ctx.popTypeRegistryFrame();
        setLastError(handle, "isolation begin: obligation frame alloc failed", .{});
        return ONEZ_ERR_ALLOC;
    };
    ctx.protocol_obligations = .{};

    return ONEZ_OK;
}

/// Pop an isolation frame, discarding type-system side effects created
/// since the matching onez_isolation_begin call.
export fn onez_isolation_end(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;

    clearLastError(handle);

    if (handle.saved_obligation_frames.items.len == 0) {
        setLastError(handle, "onez_isolation_end called without matching begin", .{});
        return ONEZ_ERR_ISOLATION_UNDERFLOW;
    }

    ctx.protocol_obligations.deinit(ctx.allocator);
    ctx.protocol_obligations = handle.saved_obligation_frames.pop().?;

    ctx.popDispatchFrame();
    ctx.popTypeRegistryFrame();

    return ONEZ_OK;
}

/// Convenience wrapper: evaluate code within an isolation scope.
/// Equivalent to begin + eval + end. The end always runs, even if eval failed.
export fn onez_eval_isolated(ptr: ?*anyopaque, code: [*]const u8, len: usize) c_int {
    const begin_rc = onez_isolation_begin(ptr);
    if (begin_rc != ONEZ_OK) return begin_rc;

    const eval_rc = onez_eval(ptr, code, len);
    const end_rc = onez_isolation_end(ptr);

    if (eval_rc != ONEZ_OK) return eval_rc;
    return end_rc;
}

/// Run static analysis on a chunk of 1z source without executing
/// non-definition statements.
///
/// Parses the buffer line-by-line using the same statement processor as
/// `onez_eval`. Definition statements (those ending in `;`) are registered
/// into the current local frame; non-definition statements are parsed and
/// dropped. After parsing, stack-effect inference, type checking, and arity
/// validation run over every compound word whose `source_file` matches
/// `ctx.current_source`. Diagnostics are copied onto the handle and can be
/// iterated with the `onez_diag_*` accessors.
///
/// Definitions persist in the dictionary after the call, matching
/// `onez_eval` semantics. Hosts that want ephemeral checking wrap the call
/// in `onez_isolation_begin` / `onez_isolation_end`.
///
/// Returns `ONEZ_OK` (0) when no error-severity diagnostics were produced
/// and parsing succeeded; returns `1` if any error diagnostic was produced
/// or parsing failed. Warnings and notes do not affect the return code.
/// Parse errors surface through `onez_last_error` and do not populate the
/// diagnostics list.
export fn onez_check(ptr: ?*anyopaque, code: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();
    const source = code[0..len];

    ctx.clearExecutionDetails();
    clearLastError(handle);
    clearDiagnostics(handle);

    const prev_check_mode = ctx.check_mode;
    ctx.check_mode = true;
    defer ctx.check_mode = prev_check_mode;

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        start = end + 1;

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                captureError(handle, err);
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0 and Context.isDefinitionStatement(instrs)) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        captureError(handle, err);
                        return 1;
                    };
                }
                processor.reset();
            },
        }
    }

    switch (processor.flush(alloc, ctx)) {
        .needs_more_input => {},
        .parse_error => |err| {
            captureError(handle, err);
            return 1;
        },
        .complete => |instrs| {
            if (instrs.len > 0 and Context.isDefinitionStatement(instrs)) {
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                    captureError(handle, err);
                    return 1;
                };
            }
        },
    }

    _ = call_graph.build(&ctx.dictionary, &ctx.dispatch, ctx.quotationAllocator()) catch {
        setLastError(handle, "onez_check: failed to build call graph", .{});
        return 1;
    };

    const settings = effect_inference.readCheckPragmas(ctx);

    var engine = effect_inference.InferenceEngine.init(
        &ctx.dictionary,
        &ctx.dispatch,
        ctx.local_frames.items,
        ctx.quotationAllocator(),
        settings.severity_override,
        settings.suppressed,
        settings.suppress_undeclared,
        &ctx.builtin_type_values,
        ctx.getAnyTypeSentinel(),
        settings.type_check_mode,
        settings.arity_check_mode,
        ctx,
    );
    defer engine.deinit();

    engine.analyzeAll(ctx.current_source) catch {
        setLastError(handle, "onez_check: effect inference failed", .{});
        return 1;
    };

    // Deep-copy diagnostics BEFORE engine.deinit frees their `message` slices.
    const handle_alloc = handle.gpa.allocator();
    handle.diagnostics.ensureTotalCapacity(handle_alloc, engine.getDiagnostics().len) catch {
        setLastError(handle, "onez_check: failed to allocate diagnostics buffer", .{});
        return 1;
    };

    var any_error = false;
    for (engine.getDiagnostics()) |diag| {
        const msg_copy = handle_alloc.dupeZ(u8, diag.message) catch {
            setLastError(handle, "onez_check: failed to copy diagnostic message", .{});
            return 1;
        };
        const word_copy = handle_alloc.dupeZ(u8, diag.word_name) catch {
            freeZ(handle_alloc, msg_copy);
            setLastError(handle, "onez_check: failed to copy diagnostic word", .{});
            return 1;
        };
        var source_copy: ?[:0]const u8 = null;
        if (diag.source_file) |sf| {
            source_copy = handle_alloc.dupeZ(u8, sf) catch {
                freeZ(handle_alloc, msg_copy);
                freeZ(handle_alloc, word_copy);
                setLastError(handle, "onez_check: failed to copy diagnostic source", .{});
                return 1;
            };
        }

        handle.diagnostics.appendAssumeCapacity(.{
            .severity = diag.severity,
            .message = msg_copy,
            .source_file = source_copy,
            .source_line = diag.source_line,
            .word_name = word_copy,
        });

        if (diag.severity == .err) any_error = true;
    }

    return if (any_error) 1 else ONEZ_OK;
}

/// Return the number of diagnostics produced by the most recent
/// `onez_check` call on this handle.
export fn onez_diag_count(ptr: ?*anyopaque) usize {
    const handle = castHandle(ptr) orelse return 0;
    return handle.diagnostics.items.len;
}

/// Return the severity of the diagnostic at `index`, one of
/// `ONEZ_DIAG_ERROR`, `ONEZ_DIAG_WARNING`, `ONEZ_DIAG_NOTE`. Returns `-1`
/// if the handle is null or the index is out of range.
export fn onez_diag_severity(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return -1;
    if (index >= handle.diagnostics.items.len) return -1;
    return @intFromEnum(handle.diagnostics.items[index].severity);
}

/// Return the human-readable message of the diagnostic at `index`. The
/// returned pointer is valid until the next `onez_check` call on this
/// handle. Returns null on null handle or out-of-range index.
export fn onez_diag_message(ptr: ?*anyopaque, index: usize) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (index >= handle.diagnostics.items.len) return null;
    return handle.diagnostics.items[index].message.ptr;
}

/// Return the source file attributed to the diagnostic at `index`, or
/// null if the diagnostic has no associated source file or the index is
/// out of range. The returned pointer is valid until the next
/// `onez_check` call on this handle.
export fn onez_diag_source(ptr: ?*anyopaque, index: usize) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (index >= handle.diagnostics.items.len) return null;
    const src = handle.diagnostics.items[index].source_file orelse return null;
    return src.ptr;
}

/// Return the source line of the diagnostic at `index`, or `0` if the
/// line is unknown, the handle is null, or the index is out of range.
export fn onez_diag_line(ptr: ?*anyopaque, index: usize) usize {
    const handle = castHandle(ptr) orelse return 0;
    if (index >= handle.diagnostics.items.len) return 0;
    return handle.diagnostics.items[index].source_line;
}

/// Return the name of the word the diagnostic at `index` was reported
/// against. The returned pointer is valid until the next `onez_check`
/// call on this handle. Returns null on null handle or out-of-range
/// index.
export fn onez_diag_word(ptr: ?*anyopaque, index: usize) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (index >= handle.diagnostics.items.len) return null;
    return handle.diagnostics.items[index].word_name.ptr;
}

/// Register a host callback as a 1z word.
///
/// The callback receives a pointer to the 1z handle, allowing it to manipulate the 1z stack
/// and call other API functions. The callback can return a non-zero error code to indicate
/// failure, which will propagate as a runtime error in 1z.
///
/// The callback can also set the last error message on the handle to provide more details
/// about the failure, which will be included in the 1z error report.
export fn onez_register_word(ptr: ?*anyopaque, name: ?[*:0]const u8, callback: ?HostCallbackFn, user_data: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    clearLastError(handle);
    handle.ctx.clearExecutionDetails();

    const name_ptr = name orelse {
        setLastError(handle, "null name passed to onez_register_word", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const callback_fn = callback orelse {
        setLastError(handle, "null callback passed to onez_register_word", .{});
        return ONEZ_ERR_NULL_VALUE;
    };

    const name_slice = std.mem.span(name_ptr);
    if (name_slice.len == 0) {
        setLastError(handle, "empty name passed to onez_register_word", .{});
        return ONEZ_ERR_TYPE_MISMATCH;
    }

    const name_copy = handle.gpa.allocator().dupe(u8, name_slice) catch {
        setLastError(handle, "allocation failure copying word name", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer handle.gpa.allocator().free(name_copy);

    handle.host_words.append(handle.gpa.allocator(), .{ .name = name_copy }) catch {
        setLastError(handle, "allocation failure tracking host word", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer _ = handle.host_words.pop();

    handle.ctx.defineWord(name_copy, .{
        .name = name_copy,
        .action = .{ .host_callback = HostCallback{
            .handle = ptr,
            .callback = callback_fn,
            .user_data = user_data,
        } },
    }) catch |err| {
        if (handle.ctx.pending_error_message) |msg| {
            setLastError(handle, "{s}", .{msg});
        } else {
            captureError(handle, err);
        }
        return 1;
    };

    return ONEZ_OK;
}

/// Strip optional surrounding parentheses and whitespace from an effect string.
/// "( a b -- c )" -> "a b -- c"
/// "a b -- c"     -> "a b -- c"  (no change)
fn stripEffectParens(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t");
    if (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')') {
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
    }
    return s;
}

/// Register a host callback as a 1z word with an optional stack effect annotation.
///
/// The effect_str may be NULL (no effect), empty (no effect), or a stack effect
/// string such as "a b -- c" or "( a b -- c )". Parentheses are stripped
/// automatically. The effect is visible through `help` and `>word-info`.
export fn onez_register_word_with_effect(
    ptr: ?*anyopaque,
    name: ?[*:0]const u8,
    effect_str: ?[*:0]const u8,
    callback: ?HostCallbackFn,
    user_data: ?*anyopaque,
) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    clearLastError(handle);
    handle.ctx.clearExecutionDetails();

    const name_ptr = name orelse {
        setLastError(handle, "null name passed to onez_register_word_with_effect", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const callback_fn = callback orelse {
        setLastError(handle, "null callback passed to onez_register_word_with_effect", .{});
        return ONEZ_ERR_NULL_VALUE;
    };

    const name_slice = std.mem.span(name_ptr);
    if (name_slice.len == 0) {
        setLastError(handle, "empty name passed to onez_register_word_with_effect", .{});
        return ONEZ_ERR_TYPE_MISMATCH;
    }

    const parsed_effect: ?StackEffect = if (effect_str) |eptr| blk: {
        const raw = std.mem.span(eptr);
        if (raw.len == 0) break :blk null;
        const stripped = stripEffectParens(raw);
        if (std.mem.indexOf(u8, stripped, "--") == null) {
            setLastError(handle, "stack effect string must contain '--'", .{});
            return ONEZ_ERR_INVALID_EFFECT;
        }
        break :blk helpers.makeSimpleEffect(handle.ctx.quotationAllocator(), stripped) catch {
            setLastError(handle, "invalid stack effect string", .{});
            return ONEZ_ERR_INVALID_EFFECT;
        };
    } else null;

    const name_copy = handle.gpa.allocator().dupe(u8, name_slice) catch {
        setLastError(handle, "allocation failure copying word name", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer handle.gpa.allocator().free(name_copy);

    handle.host_words.append(handle.gpa.allocator(), .{ .name = name_copy }) catch {
        setLastError(handle, "allocation failure tracking host word", .{});
        return ONEZ_ERR_ALLOC;
    };
    errdefer _ = handle.host_words.pop();

    handle.ctx.defineWord(name_copy, .{
        .name = name_copy,
        .stack_effect = parsed_effect,
        .action = .{ .host_callback = HostCallback{
            .handle = ptr,
            .callback = callback_fn,
            .user_data = user_data,
        } },
    }) catch |err| {
        if (handle.ctx.pending_error_message) |msg| {
            setLastError(handle, "{s}", .{msg});
        } else {
            captureError(handle, err);
        }
        return 1;
    };

    return ONEZ_OK;
}

/// Remove a previously registered host word from the dictionary.
export fn onez_unregister_word(ptr: ?*anyopaque, name: ?[*:0]const u8) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    clearLastError(handle);
    handle.ctx.clearExecutionDetails();

    const name_ptr = name orelse {
        setLastError(handle, "null name passed to onez_unregister_word", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const name_slice = std.mem.span(name_ptr);

    const definition = handle.ctx.lookupWord(name_slice) orelse {
        setLastError(handle, "word '{s}' not found", .{name_slice});
        return ONEZ_ERR_KEY_NOT_FOUND;
    };

    switch (definition.action) {
        .host_callback => {},
        else => {
            setLastError(handle, "word '{s}' is not a host callback", .{name_slice});
            return ONEZ_ERR_NOT_HOST_WORD;
        },
    }

    _ = handle.ctx.removeWord(name_slice);

    const allocator = handle.gpa.allocator();
    for (handle.host_words.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name_slice)) {
            allocator.free(entry.name);
            _ = handle.host_words.swapRemove(i);
            break;
        }
    }

    return ONEZ_OK;
}

/// Set a custom error message from within a host callback.
// ( ctx msg len -- )
export fn onez_set_error(ptr: ?*anyopaque, msg: ?[*]const u8, len: usize) void {
    const handle = castHandle(ptr) orelse return;
    const msg_ptr = msg orelse return;
    handle.ctx.pending_error_message = std.fmt.allocPrint(
        handle.ctx.arena.allocator(),
        "{s}",
        .{msg_ptr[0..len]},
    ) catch null;
}

/// Look up a type by name. Returns an opaque handle for use with
/// onez_register_method, or NULL if the type is not found.
export fn onez_lookup_type(ptr: ?*anyopaque, name: ?[*:0]const u8) ?*anyopaque {
    const handle = castHandle(ptr) orelse return null;
    const name_ptr = name orelse return null;
    const name_slice = std.mem.span(name_ptr);

    if (name_slice.len == 0) return null;
    const tv = handle.ctx.lookupTypeValueByName(name_slice) orelse return null;

    return @ptrCast(@constCast(tv));
}

/// Register a host callback as a method on an existing generic word for
/// a specific type combination.
export fn onez_register_method(
    ptr: ?*anyopaque,
    word_name: ?[*:0]const u8,
    type_a: ?*anyopaque,
    type_b: ?*anyopaque,
    callback: ?HostCallbackFn,
    user_data: ?*anyopaque,
) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    clearLastError(handle);
    handle.ctx.clearExecutionDetails();

    const name_ptr = word_name orelse {
        setLastError(handle, "null word_name passed to onez_register_method", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const callback_fn = callback orelse {
        setLastError(handle, "null callback passed to onez_register_method", .{});
        return ONEZ_ERR_NULL_VALUE;
    };

    const name_slice = std.mem.span(name_ptr);
    if (name_slice.len == 0) {
        setLastError(handle, "empty word_name passed to onez_register_method", .{});
        return ONEZ_ERR_NULL_VALUE;
    }

    const dispatch_id = handle.ctx.resolveDispatchId(name_slice) orelse {
        setLastError(handle, "word '{s}' not found in dictionary", .{name_slice});
        return ONEZ_ERR_WORD_NOT_FOUND;
    };

    const any_sentinel = handle.ctx.getDispatchAnySentinel();
    const unary_sentinel = handle.ctx.getDispatchUnarySentinel();

    const desc_a: *const value_mod.TypeDescriptor = if (type_a) |ta|
        (@as(*const TypeValue, @ptrCast(@alignCast(ta)))).descriptor orelse {
            setLastError(handle, "type_a has no descriptor", .{});
            return ONEZ_ERR_TYPE_MISMATCH;
        }
    else
        any_sentinel.descriptor.?;

    const desc_b: *const value_mod.TypeDescriptor = if (type_b) |tb|
        (@as(*const TypeValue, @ptrCast(@alignCast(tb)))).descriptor orelse {
            setLastError(handle, "type_b has no descriptor", .{});
            return ONEZ_ERR_TYPE_MISMATCH;
        }
    else if (type_a != null)
        any_sentinel.descriptor.?
    else
        unary_sentinel.descriptor.?;

    const key = DispatchKey{
        .dispatch_id = dispatch_id,
        .type_a = desc_a,
        .type_b = desc_b,
    };

    const entry = DispatchEntry{
        .body = .{ .host_callback = HostCallback{
            .handle = ptr,
            .callback = callback_fn,
            .user_data = user_data,
        } },
    };

    handle.ctx.registerDispatch(key, entry, true) catch |err| {
        captureError(handle, err);
        return ONEZ_ERR_ALLOC;
    };

    return ONEZ_OK;
}

export fn onez_push_int(ptr: ?*anyopaque, value: i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .fixnum = value }) catch {
        setLastError(handle, "allocation failure pushing int", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_double(ptr: ?*anyopaque, value: f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .float = value }) catch {
        setLastError(handle, "allocation failure pushing double", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_bool(ptr: ?*anyopaque, value: bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .boolean = value }) catch {
        setLastError(handle, "allocation failure pushing bool", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_string(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying string", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stack.push(.{ .string = copy }) catch {
        setLastError(handle, "allocation failure pushing string", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_pop_value(ptr: ?*anyopaque, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop value from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    const slot = handle.ctx.quotationAllocator().create(Value) catch {
        handle.ctx.stack.push(val) catch {};
        setLastError(handle, "allocation failure creating value handle", .{});
        return ONEZ_ERR_ALLOC;
    };
    slot.* = val;
    out.* = slot;
    return ONEZ_OK;
}

export fn onez_push_value(ptr: ?*anyopaque, val_ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_push_value", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    handle.ctx.stack.push(value.*) catch {
        setLastError(handle, "allocation failure pushing value", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_value_type(val_ptr: ?*anyopaque) c_int {
    const vp = val_ptr orelse return ONEZ_TYPE_UNKNOWN;
    const value: *const Value = @ptrCast(@alignCast(vp));
    return valueTypeToInt(value.*);
}

export fn onez_array_length(val_ptr: ?*anyopaque) usize {
    const vp = val_ptr orelse return 0;
    const value: *const Value = @ptrCast(@alignCast(vp));
    return switch (value.*) {
        .array => |a| a.len,
        else => 0,
    };
}

export fn onez_array_get(ptr: ?*anyopaque, val_ptr: ?*anyopaque, index: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_array_get", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .array => |a| {
            if (index >= a.len) {
                setLastError(handle, "index {d} out of range for array of length {d}", .{ index, a.len });
                return ONEZ_ERR_INDEX_OUT_OF_RANGE;
            }
            const slot = handle.ctx.quotationAllocator().create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = a[index];
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected array, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_hash_get(ptr: ?*anyopaque, val_ptr: ?*anyopaque, key: [*]const u8, key_len: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_hash_get", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .hash => |h| {
            const found = h.get(key[0..key_len]) orelse {
                setLastError(handle, "key not found", .{});
                return ONEZ_ERR_KEY_NOT_FOUND;
            };
            const slot = handle.ctx.quotationAllocator().create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = found;
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected hash, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_hash_keys(ptr: ?*anyopaque, val_ptr: ?*anyopaque, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_hash_keys", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .hash => |h| {
            const alloc = handle.ctx.quotationAllocator();
            const count = h.count();
            const keys = alloc.alloc(Value, count) catch {
                setLastError(handle, "allocation failure creating keys array", .{});
                return ONEZ_ERR_ALLOC;
            };
            var i: usize = 0;
            var it = h.iterator();
            while (it.next()) |entry| {
                keys[i] = .{ .symbol = entry.key_ptr.* };
                i += 1;
            }
            const slot = alloc.create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = .{ .array = keys };
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected hash, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_struct_get(ptr: ?*anyopaque, val_ptr: ?*anyopaque, field: [*]const u8, field_len: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_struct_get", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .struct_instance => |si| {
            const field_name = field[0..field_len];
            for (si.struct_type.fields, 0..) |f, i| {
                if (std.mem.eql(u8, f, field_name)) {
                    const slot = handle.ctx.quotationAllocator().create(Value) catch {
                        setLastError(handle, "allocation failure creating value handle", .{});
                        return ONEZ_ERR_ALLOC;
                    };
                    slot.* = si.fields[i];
                    out.* = slot;
                    return ONEZ_OK;
                }
            }
            setLastError(handle, "field not found: {s}", .{field_name});
            return ONEZ_ERR_KEY_NOT_FOUND;
        },
        else => {
            setLastError(handle, "type mismatch: expected struct, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_push_symbol(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying symbol", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stack.push(.{ .symbol = copy }) catch {
        setLastError(handle, "allocation failure pushing symbol", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_array(ptr: ?*anyopaque, handles: [*]const ?*anyopaque, count: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const alloc = handle.ctx.quotationAllocator();
    const values = alloc.alloc(Value, count) catch {
        setLastError(handle, "allocation failure creating array", .{});
        return ONEZ_ERR_ALLOC;
    };
    for (0..count) |i| {
        const elem_ptr = handles[i] orelse {
            setLastError(handle, "null element handle at index {d}", .{i});
            return ONEZ_ERR_NULL_VALUE;
        };
        const elem: *const Value = @ptrCast(@alignCast(elem_ptr));
        values[i] = elem.*;
    }
    handle.ctx.stack.push(.{ .array = values }) catch {
        setLastError(handle, "allocation failure pushing array", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_virtual_type_name(val_ptr: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) c_int {
    const vp = val_ptr orelse return ONEZ_ERR_NULL_VALUE;
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .tagged => |t| {
            out_ptr.* = t.tag.name.ptr;
            out_len.* = t.tag.name.len;
            return ONEZ_OK;
        },
        else => return ONEZ_ERR_TYPE_MISMATCH,
    }
}

export fn onez_virtual_unwrap(ptr: ?*anyopaque, val_ptr: ?*anyopaque, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_virtual_unwrap", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .tagged => |t| {
            const slot = handle.ctx.quotationAllocator().create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = t.inner.*;
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected tagged, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_int(ptr: ?*anyopaque, out: *i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop int from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .fixnum => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected fixnum, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_double(ptr: ?*anyopaque, out: *f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop double from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .float => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected float, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_bool(ptr: ?*anyopaque, out: *bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop bool from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .boolean => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected boolean, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_string(ptr: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop string from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .string => |s| {
            out_ptr.* = s.ptr;
            out_len.* = s.len;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected string, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_stack_depth(ptr: ?*anyopaque) usize {
    const handle = castHandle(ptr) orelse return 0;
    return handle.ctx.stack.depth();
}

export fn onez_stack_type(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.peekN(index) catch return ONEZ_ERR_NULL_HANDLE;
    return valueTypeToInt(val);
}

export fn onez_last_error(ptr: ?*anyopaque) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.last_error) |err| return err.ptr else return null;
}

export fn onez_set_stdlib_path(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying stdlib path", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stdlib_path = copy;
    return ONEZ_OK;
}

export fn onez_set_source(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying source name", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.current_source = copy;
    return ONEZ_OK;
}

export fn onez_set_args(ptr: ?*anyopaque, argc: c_int, argv: [*]const [*:0]const u8) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const allocator = handle.gpa.allocator();

    if (argc > 0) {
        const count: usize = @intCast(argc);
        const args = allocator.alloc([]const u8, count) catch return ONEZ_ERR_ALLOC;
        for (0..count) |idx| {
            args[idx] = std.mem.span(argv[idx]);
        }
        handle.ctx.program_args = args;

        const argv0 = std.mem.span(argv[0]);
        handle.ctx.current_source = handle.ctx.quotationAllocator().dupe(u8, argv0) catch argv0;
    }

    return ONEZ_OK;
}

/// Register library names that are statically linked into the executable.
///
/// When `lib-open` encounters one of these names at runtime, it uses
/// `dlopen(NULL)`, relying on the main executable's symbol table, instead of
/// loading a shared library. This enables AOT executables built with
/// `--link-static=LIB` to resolve FFI symbols without a runtime .so/.dylib.
///
/// This is a single-shot, non-additive call: it replaces any previously
/// registered list rather than appending to it. Must be called before
/// running any 1z code.
///
/// Also usable from the C embedding API -- any host that statically links
/// a library can call this to get the same behavior.
export fn onez_set_static_libs(ptr: ?*anyopaque, names: [*]const [*:0]const u8, count: u32) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const allocator = handle.gpa.allocator();
    const n: usize = @intCast(count);

    const libs = allocator.alloc([]const u8, n) catch return ONEZ_ERR_ALLOC;
    for (0..n) |i| {
        const name = std.mem.span(names[i]);
        libs[i] = allocator.dupe(u8, name) catch {
            for (0..i) |j| allocator.free(libs[j]);
            allocator.free(libs);
            return ONEZ_ERR_ALLOC;
        };
    }

    for (handle.ctx.static_ffi_libs) |old| allocator.free(old);
    if (handle.ctx.static_ffi_libs.len > 0) allocator.free(handle.ctx.static_ffi_libs);

    handle.ctx.static_ffi_libs = libs;
    return ONEZ_OK;
}

// =========================================================================
// Interpreter fallback control
// =========================================================================

export fn onez_set_interpreter_fallback(ptr: ?*anyopaque, allowed: bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.allow_interpreted_fallback = allowed;
    return ONEZ_OK;
}

// =========================================================================
// Debugger
// =========================================================================

/// Activate the debugger. Allocates and attaches a Debugger to the context.
/// If the debugger was previously disabled, reättaches the existing instance,
/// preserving breakpoints and callbacks.
export fn onez_debug_enable(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const allocator = handle.gpa.allocator();

    if (handle.debugger == null) {
        const dbg = allocator.create(debugger_mod.Debugger) catch return ONEZ_ERR_ALLOC;
        dbg.* = debugger_mod.Debugger.init(allocator);
        handle.debugger = dbg;
    }

    const dbg = handle.debugger.?;

    // Wire up stored C callback if present.
    if (handle.debug_callback) |cb| {
        dbg.events.c_callback = cb;
        dbg.events.c_handle = ptr;
        dbg.events.c_userdata = handle.debug_userdata;
    }

    handle.ctx.debugger = dbg;
    return ONEZ_OK;
}

/// Deactivate the debugger. Detaches from the context but preserves the
/// debugger instance so breakpoints and callbacks survive re-enable.
export fn onez_debug_disable(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    if (handle.debugger == null) return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;

    handle.ctx.debugger = null;
    return ONEZ_OK;
}

/// Register or replace the debug event callback. May be called before or
/// after onez_debug_enable. The callback fires from within the execution
/// loop when the debugger pauses; the host calls stepping APIs from within
/// the callback to control what happens next.
export fn onez_debug_set_callback(
    ptr: ?*anyopaque,
    callback: ?OnezDebugCallbackFn,
    userdata: ?*anyopaque,
) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;

    handle.debug_callback = callback;
    handle.debug_userdata = userdata;

    // If the debugger is already active, update the emitter immediately.
    if (handle.debugger) |dbg| {
        dbg.events.c_callback = callback;
        dbg.events.c_handle = ptr;
        dbg.events.c_userdata = userdata;
    }

    return ONEZ_OK;
}

/// Set stepper mode to step_into. Pauses before the next instruction.
export fn onez_debug_step_into(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const dbg = handle.debugger orelse return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    dbg.stepper.mode = .step_into;
    return ONEZ_OK;
}

/// Set stepper mode to step_over. Pauses when returning to the current
/// call depth or shallower.
export fn onez_debug_step_over(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const dbg = handle.debugger orelse return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    dbg.stepper.mode = .step_over;
    dbg.stepper.target_depth = handle.ctx.call_stack.items.len;
    return ONEZ_OK;
}

/// Set stepper mode to step_finish. Runs until the current word returns.
export fn onez_debug_step_finish(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const dbg = handle.debugger orelse return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    dbg.stepper.mode = .step_finish;
    dbg.stepper.target_depth = handle.ctx.call_stack.items.len;
    return ONEZ_OK;
}

/// Set stepper mode to continue. Runs until the next breakpoint or end.
export fn onez_debug_continue(ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const dbg = handle.debugger orelse return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    dbg.stepper.mode = .continue_running;
    return ONEZ_OK;
}

// =========================================================================
// Breakpoints
// =========================================================================

/// Add a word-name breakpoint. Returns the breakpoint ID (>= 1), or 0
/// if the debugger is not active or allocation fails.
export fn onez_breakpoint_add_word(ptr: ?*anyopaque, name: ?[*:0]const u8) u32 {
    const handle = castHandle(ptr) orelse return 0;
    const dbg = handle.debugger orelse return 0;
    const n = name orelse return 0;
    return dbg.breakpoints.addWord(std.mem.sliceTo(n, 0));
}

/// Add a source-location breakpoint. Returns the breakpoint ID (>= 1),
/// or 0 if the debugger is not active or allocation fails.
export fn onez_breakpoint_add_source(
    ptr: ?*anyopaque,
    file: ?[*]const u8,
    file_len: usize,
    line: usize,
) u32 {
    const handle = castHandle(ptr) orelse return 0;
    const dbg = handle.debugger orelse return 0;
    const f = file orelse return 0;
    return dbg.breakpoints.addSourceLocation(f[0..file_len], line);
}

/// Add a conditional breakpoint. Breaks on the named word when the 1z
/// condition expression evaluates to true on a cloned stack. Returns the
/// breakpoint ID (>= 1), or 0 on failure.
export fn onez_breakpoint_add_conditional(
    ptr: ?*anyopaque,
    word: ?[*:0]const u8,
    condition: ?[*:0]const u8,
) u32 {
    const handle = castHandle(ptr) orelse return 0;
    const dbg = handle.debugger orelse return 0;
    const w = word orelse return 0;
    const c = condition orelse return 0;
    return dbg.breakpoints.addConditional(
        std.mem.sliceTo(w, 0),
        std.mem.sliceTo(c, 0),
    );
}

/// Enable a breakpoint by ID.
export fn onez_breakpoint_enable(ptr: ?*anyopaque, id: u32) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const dbg = handle.debugger orelse return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    if (dbg.breakpoints.enable(id)) return ONEZ_OK;
    return ONEZ_ERR_BREAKPOINT_NOT_FOUND;
}

/// Disable a breakpoint by ID.
export fn onez_breakpoint_disable(ptr: ?*anyopaque, id: u32) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const dbg = handle.debugger orelse return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    if (dbg.breakpoints.disable(id)) return ONEZ_OK;
    return ONEZ_ERR_BREAKPOINT_NOT_FOUND;
}

/// Delete a breakpoint by ID.
export fn onez_breakpoint_delete(ptr: ?*anyopaque, id: u32) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const dbg = handle.debugger orelse return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    if (dbg.breakpoints.delete(id)) return ONEZ_OK;
    return ONEZ_ERR_BREAKPOINT_NOT_FOUND;
}

// =========================================================================
// Debug state inspection
// =========================================================================

const ONEZ_LOCAL_COMPOUND: c_int = 0;
const ONEZ_LOCAL_NATIVE: c_int = 1;

/// Return the name of the word currently being executed.
export fn onez_debug_current_word(ptr: ?*anyopaque) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.debugger == null) return null;
    const stack = handle.ctx.call_stack.items;
    if (stack.len == 0) return null;
    const frame = stack[stack.len - 1];
    const duped = handle.ctx.quotationAllocator().dupeZ(u8, frame.word_name) catch return null;
    return duped.ptr;
}

/// Return the source location of the current instruction.
export fn onez_debug_current_source(ptr: ?*anyopaque, out_file: *?[*:0]const u8, out_line: *c_uint, out_col: *c_uint) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    if (handle.debugger == null) return ONEZ_ERR_DEBUGGER_NOT_ACTIVE;
    const stack = handle.ctx.call_stack.items;
    if (stack.len == 0) return ONEZ_ERR_INDEX_OUT_OF_RANGE;
    const frame = stack[stack.len - 1];
    const duped = handle.ctx.quotationAllocator().dupeZ(u8, frame.source) catch return ONEZ_ERR_ALLOC;
    out_file.* = duped.ptr;
    out_line.* = @intCast(frame.line);
    out_col.* = @intCast(frame.column);
    return ONEZ_OK;
}

/// Return the number of frames on the call stack.
export fn onez_debug_frame_count(ptr: ?*anyopaque) usize {
    const handle = castHandle(ptr) orelse return 0;
    if (handle.debugger == null) return 0;
    return handle.ctx.call_stack.items.len;
}

/// Helper to access a call stack frame by debugger index (0 = innermost).
fn getCallFrame(handle: *OnezHandle, index: usize) ?context_mod.CallFrame {
    const stack = handle.ctx.call_stack.items;
    if (index >= stack.len) return null;
    return stack[stack.len - 1 - index];
}

/// Return the word name at call stack frame `index` (0 = innermost).
export fn onez_debug_frame_word(ptr: ?*anyopaque, index: usize) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.debugger == null) return null;
    const frame = getCallFrame(handle, index) orelse return null;
    const duped = handle.ctx.quotationAllocator().dupeZ(u8, frame.word_name) catch return null;
    return duped.ptr;
}

/// Return the source file at call stack frame `index` (0 = innermost).
export fn onez_debug_frame_file(ptr: ?*anyopaque, index: usize) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.debugger == null) return null;
    const frame = getCallFrame(handle, index) orelse return null;
    const duped = handle.ctx.quotationAllocator().dupeZ(u8, frame.source) catch return null;
    return duped.ptr;
}

/// Return the source line number at call stack frame `index` (0 = innermost).
export fn onez_debug_frame_line(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return -1;
    if (handle.debugger == null) return -1;
    const frame = getCallFrame(handle, index) orelse return -1;
    return @intCast(frame.line);
}

/// Return the source column at call stack frame `index` (0 = innermost).
export fn onez_debug_frame_column(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return -1;
    if (handle.debugger == null) return -1;
    const frame = getCallFrame(handle, index) orelse return -1;
    return @intCast(frame.column);
}

/// Helper to get the nth entry from the innermost local frame.
fn getLocalEntry(handle: *OnezHandle, index: usize) ?struct { name: []const u8, kind: c_int } {
    const frames = handle.ctx.local_frames.items;
    if (frames.len == 0) return null;
    const frame = frames[frames.len - 1];
    var iter = frame.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        if (i == index) {
            const kind: c_int = switch (entry.value_ptr.*.action) {
                .native, .host_callback => ONEZ_LOCAL_NATIVE,
                .compound => ONEZ_LOCAL_COMPOUND,
            };
            return .{ .name = entry.key_ptr.*, .kind = kind };
        }
        i += 1;
    }
    return null;
}

/// Return the number of local bindings in the innermost local frame.
export fn onez_debug_local_count(ptr: ?*anyopaque) usize {
    const handle = castHandle(ptr) orelse return 0;
    if (handle.debugger == null) return 0;
    const frames = handle.ctx.local_frames.items;
    if (frames.len == 0) return 0;
    return frames[frames.len - 1].count();
}

/// Return the name of the local binding at `index` in the innermost frame.
export fn onez_debug_local_name(ptr: ?*anyopaque, index: usize) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.debugger == null) return null;
    const entry = getLocalEntry(handle, index) orelse return null;
    const duped = handle.ctx.quotationAllocator().dupeZ(u8, entry.name) catch return null;
    return duped.ptr;
}

/// Return the kind of the local binding at `index` in the innermost frame.
export fn onez_debug_local_kind(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return -1;
    if (handle.debugger == null) return -1;
    const entry = getLocalEntry(handle, index) orelse return -1;
    return entry.kind;
}

/// Non-destructive read of the value at stack position `index` (0 = top).
export fn onez_stack_peek(ptr: ?*anyopaque, index: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.peekN(index) catch return ONEZ_ERR_INDEX_OUT_OF_RANGE;
    const slot = handle.ctx.quotationAllocator().create(Value) catch return ONEZ_ERR_ALLOC;
    slot.* = val;
    out.* = slot;
    return ONEZ_OK;
}

// =========================================================================
// Module loading
// =========================================================================

export fn onez_load_file(ptr: ?*anyopaque, path: [*]const u8, path_len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();
    const filepath = path[0..path_len];

    ctx.clearExecutionDetails();
    clearLastError(handle);

    const resolved = misc.resolveLoadPath(ctx, filepath, alloc) orelse {
        setLastError(handle, "file not found: {s}", .{filepath});
        return ONEZ_ERR_LOAD_FAILED;
    };

    const resolved_module = misc.classifyResolved(resolved) orelse {
        setLastError(handle, "file not found: {s}", .{filepath});
        return ONEZ_ERR_LOAD_FAILED;
    };

    misc.nativeLoadImpl(ctx, ctx.module_cache_value, filepath, alloc, resolved_module) catch |err| {
        captureError(handle, err);
        return ONEZ_ERR_LOAD_FAILED;
    };

    return ONEZ_OK;
}

export fn onez_use_module(ptr: ?*anyopaque, name: [*]const u8, name_len: usize) c_int {
    if (comptime is_freestanding) return ONEZ_ERR_LOAD_FAILED;
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();
    const mod_name = name[0..name_len];

    ctx.clearExecutionDetails();
    clearLastError(handle);

    const resolved = misc.resolveLoadPath(ctx, mod_name, alloc) orelse {
        setLastError(handle, "module not found: {s}", .{mod_name});
        return ONEZ_ERR_LOAD_FAILED;
    };

    // Check cache first
    const module = if (ctx.module_cache_value.map.get(resolved)) |cached| blk: {
        switch (cached) {
            .module => |m| break :blk m,
            else => {
                setLastError(handle, "cached value for '{s}' is not a module", .{mod_name});
                return ONEZ_ERR_LOAD_FAILED;
            },
        }
    } else blk: {
        // Load the module
        const resolved_module = misc.classifyResolved(resolved) orelse {
            setLastError(handle, "module not found: {s}", .{mod_name});
            return ONEZ_ERR_LOAD_FAILED;
        };
        misc.nativeLoadImpl(ctx, ctx.module_cache_value, mod_name, alloc, resolved_module) catch |err| {
            captureError(handle, err);
            return ONEZ_ERR_LOAD_FAILED;
        };
        // Pop the module from stack
        const val = ctx.stack.pop() catch {
            setLastError(handle, "internal error: module not on stack after load", .{});
            return ONEZ_ERR_LOAD_FAILED;
        };
        switch (val) {
            .module => |m| break :blk m,
            else => {
                setLastError(handle, "internal error: loaded value is not a module", .{});
                return ONEZ_ERR_LOAD_FAILED;
            },
        }
    };

    // Import all public words from the module
    var iter = module.words.iterator();
    while (iter.next()) |entry| {
        misc.importWord(ctx, entry.key_ptr.*, entry.value_ptr.*, module) catch |err| {
            captureError(handle, err);
            return ONEZ_ERR_LOAD_FAILED;
        };
    }

    return ONEZ_OK;
}

// =========================================================================
// AOT Runtime API
// =========================================================================

const ir_codegen = @import("ir_codegen.zig");
const JitContext = ir_codegen.JitContext;

export fn onez_runtime_register_compiled(ptr: ?*anyopaque, table: [*]const ?*const anyopaque, names: [*]const ?[*:0]const u8, size: u32) i32 {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;

    ctx.jit_dispatch.ensureCapacity(size) catch return ONEZ_ERR_ALLOC;
    for (0..size) |i| {
        if (names[i]) |name_ptr| {
            const entry = ctx.jit_dispatch.getMut(@intCast(i)) orelse continue;
            entry.word_name = std.mem.span(name_ptr);
        }
        if (table[i]) |code_ptr| {
            ctx.jit_dispatch.setCodePtr(@intCast(i), code_ptr);
        }
    }
    return ONEZ_OK;
}

export fn onez_runtime_register_quotations(ptr: ?*anyopaque, table: [*]const ?*const anyopaque, size: u32) i32 {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.aot_quotation_fns = context_mod.AotQuotationFnTable{ .table = table, .size = size };
    return ONEZ_OK;
}

export fn onez_runtime_run(ptr: ?*anyopaque, entry_word_id: u32) i32 {
    const handle = castHandle(ptr) orelse return 1;
    const ctx = handle.ctx;

    const entry = ctx.jit_dispatch.get(entry_word_id) orelse return 1;
    var code_ptr = entry.code_ptr orelse return 1;

    var jit_ctx = JitContext{
        .items_ptr = ctx.stack.items.items.ptr,
        .sp_ptr = &ctx.stack.items.items.len,
        .capacity = ctx.stack.items.capacity,
        .ctx = ctx,
    };
    var func: *const fn (*JitContext) callconv(.c) i32 = @ptrCast(@alignCast(code_ptr));
    var status = func(&jit_ctx);

    // Trampoline loop for tail calls (status 3).
    while (status == 3) {
        const target_id = jit_ctx.trampoline_target;
        const target_entry = ctx.jit_dispatch.get(target_id) orelse return 1;
        code_ptr = target_entry.code_ptr orelse return 1;
        jit_ctx.items_ptr = ctx.stack.items.items.ptr;
        jit_ctx.capacity = ctx.stack.items.capacity;
        func = @ptrCast(@alignCast(code_ptr));
        status = func(&jit_ctx);
    }

    return if (status == 0) 0 else 1;
}

export fn onez_print_error(ptr: ?*anyopaque) void {
    const handle = castHandle(ptr) orelse return;
    const ctx = handle.ctx;

    // No stderr on freestanding; the bare-metal program has its own routing.
    if (is_freestanding) return;

    const stderr_file: std.fs.File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);

    const details = ctx.error_details.items;
    if (details.len > 0) {
        const detail = details[0];
        stderr.interface.print("{s}:{d}: error '{s}'", .{ detail.source, detail.line, detail.error_type }) catch {};

        if (detail.word_name != null and !std.mem.eql(u8, detail.message, detail.word_name.?)) {
            stderr.interface.print(" {s}", .{detail.message}) catch {};
        }

        if (detail.word_name) |word_name| {
            stderr.interface.print(" at word '{s}'", .{word_name}) catch {};
        }
        stderr.interface.writeAll("\n") catch {};

        if (detail.stack_effect_str) |se| {
            stderr.interface.print("  stack effect: {s}\n", .{se}) catch {};
        }
        if (detail.hint) |hint| {
            stderr.interface.print("  hint: {s}\n", .{hint}) catch {};
        }

        if (details.len > 1) {
            for (details[1..]) |frame| {
                stderr.interface.print("  called from {s}:{d}: {s}\n", .{
                    frame.source,
                    frame.line,
                    frame.word_name orelse frame.message,
                }) catch {};
            }
        }
    } else if (ctx.jit_pending_error) |err| {
        var kebab_buf: [128]u8 = undefined;
        const kebab_name = pascalToKebabRuntime(@errorName(err), &kebab_buf);
        stderr.interface.print("error.{s}\n", .{kebab_name}) catch {};
    } else {
        stderr.interface.writeAll("error: unknown runtime error\n") catch {};
    }

    stderr.interface.flush() catch {};
    ctx.clearExecutionDetails();
}

fn castHandle(ptr: ?*anyopaque) ?*OnezHandle {
    const p = ptr orelse return null;
    return @ptrCast(@alignCast(p));
}

fn clearLastError(handle: *OnezHandle) void {
    if (handle.last_error) |msg| {
        handle.gpa.allocator().free(@as([]const u8, msg.ptr[0 .. msg.len + 1]));
        handle.last_error = null;
    }
}

fn freeZ(allocator: std.mem.Allocator, s: [:0]const u8) void {
    allocator.free(@as([]const u8, s.ptr[0 .. s.len + 1]));
}

fn clearDiagnostics(handle: *OnezHandle) void {
    const allocator = handle.gpa.allocator();
    for (handle.diagnostics.items) |entry| {
        freeZ(allocator, entry.message);
        freeZ(allocator, entry.word_name);
        if (entry.source_file) |src| {
            freeZ(allocator, src);
        }
    }
    handle.diagnostics.clearRetainingCapacity();
}

fn setLastError(handle: *OnezHandle, comptime fmt: []const u8, args: anytype) void {
    clearLastError(handle);
    handle.last_error = allocPrintZ(handle.gpa.allocator(), fmt, args) catch null;
}

fn captureError(handle: *OnezHandle, err: anyerror) void {
    clearLastError(handle);

    const details = handle.ctx.error_details.items;
    if (details.len > 0) {
        const detail = details[0];
        handle.last_error = allocPrintZ(
            handle.gpa.allocator(),
            "{s}:{d}: error '{s}'",
            .{ detail.source, detail.line, detail.error_type },
        ) catch null;
    } else {
        handle.last_error = allocPrintZ(
            handle.gpa.allocator(),
            "{s}",
            .{@errorName(err)},
        ) catch null;
    }
}

fn allocPrintZ(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const str = try std.fmt.allocPrint(alloc, fmt, args);
    const buf = try alloc.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    alloc.free(str);
    return buf[0..str.len :0];
}

fn valueTypeToInt(val: Value) c_int {
    return switch (val) {
        .fixnum => ONEZ_TYPE_FIXNUM,
        .float => ONEZ_TYPE_FLOAT,
        .boolean => ONEZ_TYPE_BOOLEAN,
        .string => ONEZ_TYPE_STRING,
        .symbol => ONEZ_TYPE_SYMBOL,
        .array => ONEZ_TYPE_ARRAY,
        .quotation => ONEZ_TYPE_QUOTATION,
        .hash => ONEZ_TYPE_HASH,
        .vector => ONEZ_TYPE_VECTOR,
        .byte_array => ONEZ_TYPE_BYTE_ARRAY,
        .set => ONEZ_TYPE_SET,
        .mutable_map => ONEZ_TYPE_MUTABLE_MAP,
        .stream => ONEZ_TYPE_STREAM,
        .resource => ONEZ_TYPE_RESOURCE,
        .tagged => ONEZ_TYPE_TAGGED,
        .iterator => ONEZ_TYPE_ITERATOR,
        .type_val => ONEZ_TYPE_TYPE_VAL,
        .unit => ONEZ_TYPE_UNIT,
        .struct_instance => ONEZ_TYPE_STRUCT,
        else => ONEZ_TYPE_UNKNOWN,
    };
}

var test_host_callback_expected_handle: ?*anyopaque = null;
var test_host_callback_seen_handle: ?*anyopaque = null;
var test_host_callback_invocations: usize = 0;

fn resetHostCallbackTestState() void {
    test_host_callback_expected_handle = null;
    test_host_callback_seen_handle = null;
    test_host_callback_invocations = 0;
}

fn doublingHostCallback(ctx: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    test_host_callback_seen_handle = ctx;
    test_host_callback_invocations += 1;

    var input: i64 = 0;
    if (onez_pop_int(ctx, &input) != ONEZ_OK) return 1;

    const factor_ptr: *const i64 = @ptrCast(@alignCast(user_data orelse return 1));
    return onez_push_int(ctx, input * factor_ptr.*);
}

fn constantHostCallback(ctx: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    test_host_callback_seen_handle = ctx;
    test_host_callback_invocations += 1;

    const value_ptr: *const i64 = @ptrCast(@alignCast(user_data orelse return 1));
    return onez_push_int(ctx, value_ptr.*);
}

fn failingHostCallback(ctx: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const msg = "custom host error message";
    onez_set_error(ctx, msg.ptr, msg.len);
    return 1;
}

// =============================================================================
// Tests
// =============================================================================

test "init/eval/deinit round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);

    const rc = onez_eval(handle_ptr, "1 2 +", 5);
    try std.testing.expectEqual(@as(c_int, 0), rc);

    onez_deinit(handle_ptr);
}

test "register host word and invoke via dictionary lookup" {
    resetHostCallbackTestState();

    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    test_host_callback_expected_handle = handle_ptr;
    const factor: i64 = 3;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word(handle_ptr, "triple", doublingHostCallback, @constCast(&factor)));

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 14));
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "triple", 6));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
    try std.testing.expectEqual(@as(usize, 1), test_host_callback_invocations);
    try std.testing.expect(test_host_callback_seen_handle == test_host_callback_expected_handle);
}

test "register host word passes user_data and handle to callback" {
    resetHostCallbackTestState();

    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    test_host_callback_expected_handle = handle_ptr;
    const value: i64 = 77;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word(handle_ptr, "host-const", constantHostCallback, @constCast(&value)));
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "host-const", 10));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(value, out);
    try std.testing.expectEqual(@as(usize, 1), test_host_callback_invocations);
    try std.testing.expect(test_host_callback_seen_handle == test_host_callback_expected_handle);
}

test "register host word rejects invalid arguments" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 5;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_register_word(null, "x", constantHostCallback, @constCast(&value)));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_register_word(handle_ptr, null, constantHostCallback, @constCast(&value)));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_register_word(handle_ptr, "x", null, @constCast(&value)));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "set_error provides custom message on callback failure" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_register_word(handle_ptr, "fail-custom", failingHostCallback, null));

    const rc = onez_eval(handle_ptr, "fail-custom", 11);
    try std.testing.expect(rc != ONEZ_OK);

    const err_msg = onez_last_error(handle_ptr);
    try std.testing.expect(err_msg != null);
    const err_str = std.mem.span(err_msg.?);
    try std.testing.expect(std.mem.indexOf(u8, err_str, "custom host error message") != null);
}

test "unregister_word removes host word" {
    resetHostCallbackTestState();

    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 99;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word(handle_ptr, "temp-word", constantHostCallback, @constCast(&value)));

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "temp-word", 9));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);

    try std.testing.expectEqual(ONEZ_OK, onez_unregister_word(handle_ptr, "temp-word"));

    const rc = onez_eval(handle_ptr, "temp-word", 9);
    try std.testing.expect(rc != ONEZ_OK);
}

test "unregister_word returns KEY_NOT_FOUND for unknown word" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_KEY_NOT_FOUND, onez_unregister_word(handle_ptr, "no-such-word"));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "unregister_word returns NOT_HOST_WORD for native word" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_NOT_HOST_WORD, onez_unregister_word(handle_ptr, "+"));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "unregister_word rejects null arguments" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_unregister_word(null, "x"));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_unregister_word(handle_ptr, null));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "unregister_word double unregister returns KEY_NOT_FOUND" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 1;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word(handle_ptr, "once-word", constantHostCallback, @constCast(&value)));
    try std.testing.expectEqual(ONEZ_OK, onez_unregister_word(handle_ptr, "once-word"));
    try std.testing.expectEqual(ONEZ_ERR_KEY_NOT_FOUND, onez_unregister_word(handle_ptr, "once-word"));
}

test "eval error returns 1" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const rc = onez_eval(handle_ptr, "1 0 /", 5);
    try std.testing.expectEqual(@as(c_int, 1), rc);

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "null handle returns error" {
    try std.testing.expectEqual(@as(c_int, ONEZ_ERR_NULL_HANDLE), onez_eval(null, "", 0));
    onez_deinit(null); // should not crash!
}

test "push/pop int round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "push/pop double round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_double(handle_ptr, 3.14));
    var out: f64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_double(handle_ptr, &out));
    try std.testing.expectEqual(@as(f64, 3.14), out);
}

test "push/pop bool round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_bool(handle_ptr, true));
    var out: bool = false;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_bool(handle_ptr, &out));
    try std.testing.expect(out);
}

test "push/pop string round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const input = "hello";
    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, input.ptr, input.len));
    var out_ptr: [*]const u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_string(handle_ptr, &out_ptr, &out_len));
    try std.testing.expectEqual(@as(usize, 5), out_len);
    try std.testing.expectEqualStrings("hello", out_ptr[0..out_len]);
}

test "pop type mismatch preserves stack" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: f64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_pop_double(handle_ptr, &out));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "pop stack underflow" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_STACK_UNDERFLOW, onez_pop_int(handle_ptr, &out));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "stack depth" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 1));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 2));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 3));
    try std.testing.expectEqual(@as(usize, 3), onez_stack_depth(handle_ptr));
}

test "stack type at index" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, "hi", 2));

    // index 0 = top = string, index 1 = int
    try std.testing.expectEqual(ONEZ_TYPE_STRING, onez_stack_type(handle_ptr, 0));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_stack_type(handle_ptr, 1));
}

test "last_error null initially, non-null after failure" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expect(onez_last_error(handle_ptr) == null);

    var out: i64 = 0;
    _ = onez_pop_int(handle_ptr, &out);
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "set_stdlib_path updates ctx" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const path = "/custom/stdlib";
    try std.testing.expectEqual(ONEZ_OK, onez_set_stdlib_path(handle_ptr, path.ptr, path.len));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expectEqualStrings("/custom/stdlib", handle.ctx.stdlib_path.?);
}

test "set_source updates current_source" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const handle = castHandle(handle_ptr).?;
    try std.testing.expectEqualStrings("<repl>", handle.ctx.current_source);

    const name = "my-program";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, name.ptr, name.len));
    try std.testing.expectEqualStrings("my-program", handle.ctx.current_source);
}

test "null handle returns appropriate defaults" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_int(null, 42));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_double(null, 3.14));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_bool(null, true));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_string(null, "x", 1));

    var i: i64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_int(null, &i));
    var f: f64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_double(null, &f));
    var b: bool = false;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_bool(null, &b));
    var sp: [*]const u8 = undefined;
    var sl: usize = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_string(null, &sp, &sl));

    try std.testing.expectEqual(@as(usize, 0), onez_stack_depth(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_stack_type(null, 0));
    try std.testing.expect(onez_last_error(null) == null);
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_set_stdlib_path(null, "x", 1));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_set_args(null, 0, undefined));

    var vh: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_value(null, &vh));

    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_load_file(null, "x", 1));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_use_module(null, "x", 1));
}

test "set_args populates program_args and source" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const argv = [_][*:0]const u8{ "my-program", "--flag" };
    try std.testing.expectEqual(ONEZ_OK, onez_set_args(handle_ptr, 2, &argv));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expectEqual(@as(usize, 2), handle.ctx.program_args.len);
    try std.testing.expectEqualStrings("my-program", handle.ctx.program_args[0]);
    try std.testing.expectEqualStrings("--flag", handle.ctx.program_args[1]);
    try std.testing.expectEqualStrings("my-program", handle.ctx.current_source);
}

test "pop_value/push_value round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expect(val_handle != null);
    try std.testing.expectEqual(@as(usize, 0), onez_stack_depth(handle_ptr));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "pop_value stack underflow" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_STACK_UNDERFLOW, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "value_type returns correct type code" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var val_handle: ?*anyopaque = null;

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 7));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_double(handle_ptr, 1.5));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_FLOAT, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_bool(handle_ptr, true));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_BOOLEAN, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, "hi", 2));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_STRING, onez_value_type(val_handle));
}

test "value_type null handle returns UNKNOWN" {
    try std.testing.expectEqual(ONEZ_TYPE_UNKNOWN, onez_value_type(null));
}

test "push_value null ctx returns ERR_NULL_HANDLE" {
    var dummy: Value = .{ .fixnum = 0 };
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_value(null, &dummy));
}

test "push_value null value returns ERR_NULL_VALUE" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_push_value(handle_ptr, null));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "pop_value with eval-produced array" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 1 2 3 }", 9));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));
}

test "handle survives eval call" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 99));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "1 2 +", 5));
    var discard: i64 = 0;
    _ = onez_pop_int(handle_ptr, &discard);

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);
}

test "handle can be pushed multiple times" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 55));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    try std.testing.expectEqual(@as(usize, 2), onez_stack_depth(handle_ptr));

    var out1: i64 = 0;
    var out2: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out1));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out2));
    try std.testing.expectEqual(@as(i64, 55), out1);
    try std.testing.expectEqual(@as(i64, 55), out2);
}

test "array_length basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 1 2 3 }", 9));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(@as(usize, 3), onez_array_length(val_handle));
}

test "array_length null handle" {
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(null));
}

test "array_length non-array" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(val_handle));
}

test "array_get basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 10 20 30 }", 12));
    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_array_get(handle_ptr, arr_handle, 1, &elem));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(elem));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, elem));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 20), out);
}

test "array_get out of range" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 1 2 }", 7));
    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_INDEX_OUT_OF_RANGE, onez_array_get(handle_ptr, arr_handle, 5, &elem));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "array_get type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_array_get(handle_ptr, val_handle, 0, &elem));
}

test "array_get null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_array_get(null, null, 0, &elem));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_array_get(handle_ptr, null, 0, &elem));
}

test "hash_get basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ \"x\" 1 \"y\" 2 }", 17));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));
    try std.testing.expectEqual(ONEZ_TYPE_HASH, onez_value_type(hash_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_hash_get(handle_ptr, hash_handle, "x", 1, &elem));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(elem));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, elem));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 1), out);
}

test "hash_get key not found" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ \"a\" 1 }", 10));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_KEY_NOT_FOUND, onez_hash_get(handle_ptr, hash_handle, "z", 1, &elem));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "hash_get type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_hash_get(handle_ptr, val_handle, "x", 1, &elem));
}

test "hash_get null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_hash_get(null, null, "x", 1, &elem));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_hash_get(handle_ptr, null, "x", 1, &elem));
}

test "hash_keys basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ \"a\" 1 \"b\" 2 }", 16));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));

    var keys_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_hash_keys(handle_ptr, hash_handle, &keys_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(keys_handle));
    try std.testing.expectEqual(@as(usize, 2), onez_array_length(keys_handle));
}

test "hash_keys empty hash" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ }", 4));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));

    var keys_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_hash_keys(handle_ptr, hash_handle, &keys_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(keys_handle));
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(keys_handle));
}

test "hash_keys type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var keys_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_hash_keys(handle_ptr, val_handle, &keys_handle));
}

test "struct_get basic field access" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "point: struct{ x y } ;\n10 20 make-point";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var struct_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &struct_handle));
    try std.testing.expectEqual(ONEZ_TYPE_STRUCT, onez_value_type(struct_handle));

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_struct_get(handle_ptr, struct_handle, "x", 1, &field_val));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(field_val));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, field_val));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 10), out);

    var field_y: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_struct_get(handle_ptr, struct_handle, "y", 1, &field_y));
    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, field_y));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 20), out);
}

test "struct_get field not found" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "point2: struct{ x y } ;\n1 2 make-point2";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var struct_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &struct_handle));

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_KEY_NOT_FOUND, onez_struct_get(handle_ptr, struct_handle, "z", 1, &field_val));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "struct_get type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_struct_get(handle_ptr, val_handle, "x", 1, &field_val));
}

test "struct_get null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_struct_get(null, null, "x", 1, &field_val));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_struct_get(handle_ptr, null, "x", 1, &field_val));
}

test "push_symbol round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_symbol(handle_ptr, "foo", 3));
    try std.testing.expectEqual(ONEZ_TYPE_SYMBOL, onez_stack_type(handle_ptr, 0));

    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_SYMBOL, onez_value_type(val_handle));
}

test "push_symbol null handle" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_symbol(null, "x", 1));
}

test "push_array from handles" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // Create three value handles
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 10));
    var h0: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h0));

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 20));
    var h1: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h1));

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 30));
    var h2: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h2));

    const handles = [_]?*anyopaque{ h0, h1, h2 };
    try std.testing.expectEqual(ONEZ_OK, onez_push_array(handle_ptr, &handles, 3));

    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(arr_handle));
    try std.testing.expectEqual(@as(usize, 3), onez_array_length(arr_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_array_get(handle_ptr, arr_handle, 1, &elem));
    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, elem));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 20), out);
}

test "push_array empty" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const handles = [_]?*anyopaque{};
    try std.testing.expectEqual(ONEZ_OK, onez_push_array(handle_ptr, &handles, 0));

    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(arr_handle));
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(arr_handle));
}

test "push_array null element" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 1));
    var h0: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h0));

    const handles = [_]?*anyopaque{ h0, null };
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_push_array(handle_ptr, &handles, 2));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "push_array null handle" {
    const handles = [_]?*anyopaque{};
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_array(null, &handles, 0));
}

test "virtual_type_name basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "duration: virtual{ fixnum } ;\n42 make-duration";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_TAGGED, onez_value_type(val_handle));

    var name_ptr: [*]const u8 = undefined;
    var name_len: usize = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_virtual_type_name(val_handle, &name_ptr, &name_len));
    try std.testing.expectEqualStrings("duration", name_ptr[0..name_len]);
}

test "virtual_type_name type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var name_ptr: [*]const u8 = undefined;
    var name_len: usize = 0;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_virtual_type_name(val_handle, &name_ptr, &name_len));
}

test "virtual_type_name null handle" {
    var name_ptr: [*]const u8 = undefined;
    var name_len: usize = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_virtual_type_name(null, &name_ptr, &name_len));
}

test "virtual_unwrap basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "wrapper: virtual{ fixnum } ;\n99 make-wrapper";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_TAGGED, onez_value_type(val_handle));

    var inner: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_virtual_unwrap(handle_ptr, val_handle, &inner));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(inner));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, inner));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);
}

test "virtual_unwrap type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var inner: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_virtual_unwrap(handle_ptr, val_handle, &inner));
}

test "virtual_unwrap null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var inner: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_virtual_unwrap(null, null, &inner));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_virtual_unwrap(handle_ptr, null, &inner));
}

test "struct_instance returns ONEZ_TYPE_STRUCT" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "pt: struct{ a b } ;\n1 2 make-pt";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    try std.testing.expectEqual(ONEZ_TYPE_STRUCT, onez_stack_type(handle_ptr, 0));
}

test "load_file loads a file and pushes module" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const handle = castHandle(handle_ptr).?;
    const stdlib = handle.ctx.stdlib_path orelse return error.SkipZigTest;
    const path = std.fs.path.join(std.testing.allocator, &.{ stdlib, "testing.1z" }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(path);

    const depth_before = onez_stack_depth(handle_ptr);
    try std.testing.expectEqual(ONEZ_OK, onez_load_file(handle_ptr, path.ptr, path.len));
    try std.testing.expectEqual(depth_before + 1, onez_stack_depth(handle_ptr));
}

test "load_file returns error for nonexistent file" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const bad = "/nonexistent/path/file.1z";
    try std.testing.expectEqual(ONEZ_ERR_LOAD_FAILED, onez_load_file(handle_ptr, bad.ptr, bad.len));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "load_file null handle" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_load_file(null, "x", 1));
}

test "use_module loads and imports stdlib module" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const name = "testing";
    try std.testing.expectEqual(ONEZ_OK, onez_use_module(handle_ptr, name.ptr, name.len));

    const code = "3 3 \"eq\" assert=";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
}

test "use_module cached reuse" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const name = "testing";
    try std.testing.expectEqual(ONEZ_OK, onez_use_module(handle_ptr, name.ptr, name.len));
    try std.testing.expectEqual(ONEZ_OK, onez_use_module(handle_ptr, name.ptr, name.len));
}

test "use_module returns error for nonexistent module" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const name = "nonexistent-module-xyz";
    try std.testing.expectEqual(ONEZ_ERR_LOAD_FAILED, onez_use_module(handle_ptr, name.ptr, name.len));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "use_module null handle" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_use_module(null, "x", 1));
}

test "register_word_with_effect attaches stack effect visible via introspection" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 99;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word_with_effect(
        handle_ptr,
        "my-add",
        "a b -- c",
        constantHostCallback,
        @constCast(&value),
    ));

    const code = "my-add: >word-info stack-effect>> f =";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));

    var out: bool = true;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_bool(handle_ptr, &out));
    try std.testing.expectEqual(false, out); // stack-effect>> is not false
}

test "register_word_with_effect parenthesized form" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 1;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word_with_effect(
        handle_ptr,
        "paren-word",
        "( x y -- z )",
        constantHostCallback,
        @constCast(&value),
    ));

    const code = "paren-word: >word-info stack-effect>> f =";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));

    var out: bool = true;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_bool(handle_ptr, &out));
    try std.testing.expectEqual(false, out); // stack-effect>> is not false
}

test "register_word_with_effect null effect behaves like register_word" {
    resetHostCallbackTestState();
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    test_host_callback_expected_handle = handle_ptr;
    const value: i64 = 42;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word_with_effect(
        handle_ptr,
        "no-effect",
        null,
        constantHostCallback,
        @constCast(&value),
    ));

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "no-effect", 9));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "register_word_with_effect empty string means no effect" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 1;
    try std.testing.expectEqual(ONEZ_OK, onez_register_word_with_effect(
        handle_ptr,
        "empty-effect",
        "",
        constantHostCallback,
        @constCast(&value),
    ));

    const code = "empty-effect: >word-info stack-effect>>";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));

    var out: bool = true;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_bool(handle_ptr, &out));
    try std.testing.expectEqual(false, out); // no effect = false
}

test "register_word_with_effect rejects effect without --" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 1;
    try std.testing.expectEqual(ONEZ_ERR_INVALID_EFFECT, onez_register_word_with_effect(
        handle_ptr,
        "bad-effect",
        "no separator here",
        constantHostCallback,
        @constCast(&value),
    ));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "register_word_with_effect rejects null handle and null name" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 1;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_register_word_with_effect(
        null,
        "x",
        "a -- b",
        constantHostCallback,
        @constCast(&value),
    ));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_register_word_with_effect(
        handle_ptr,
        null,
        "a -- b",
        constantHostCallback,
        @constCast(&value),
    ));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_register_word_with_effect(
        handle_ptr,
        "x",
        "a -- b",
        null,
        @constCast(&value),
    ));
}

// =============================================================================
// onez_lookup_type tests
// =============================================================================

test "lookup_type returns non-null for builtin type" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const fixnum_type = onez_lookup_type(handle_ptr, "fixnum");
    try std.testing.expect(fixnum_type != null);
}

test "lookup_type returns different handles for different types" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const fixnum_type = onez_lookup_type(handle_ptr, "fixnum");
    const string_type = onez_lookup_type(handle_ptr, "string");
    try std.testing.expect(fixnum_type != null);
    try std.testing.expect(string_type != null);
    try std.testing.expect(fixnum_type != string_type);
}

test "lookup_type returns same handle for same type" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const t1 = onez_lookup_type(handle_ptr, "fixnum");
    const t2 = onez_lookup_type(handle_ptr, "fixnum");
    try std.testing.expect(t1 != null);
    try std.testing.expectEqual(t1, t2);
}

test "lookup_type returns null for nonexistent type" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(@as(?*anyopaque, null), onez_lookup_type(handle_ptr, "nonexistent-type-xyz"));
}

test "lookup_type returns null for null handle and null name" {
    try std.testing.expectEqual(@as(?*anyopaque, null), onez_lookup_type(null, "fixnum"));
    const handle_ptr = onez_init();
    defer onez_deinit(handle_ptr);
    try std.testing.expectEqual(@as(?*anyopaque, null), onez_lookup_type(handle_ptr, null));
    try std.testing.expectEqual(@as(?*anyopaque, null), onez_lookup_type(handle_ptr, ""));
}

test "lookup_type finds user-defined struct type" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "point: struct{ x y } ;";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));

    const point_type = onez_lookup_type(handle_ptr, "point");
    try std.testing.expect(point_type != null);
}

// =============================================================================
// onez_register_method tests
// =============================================================================

test "register_method unary method invoked via dispatch" {
    resetHostCallbackTestState();

    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // inspect is a generic word with methods per type
    const fixnum_type = onez_lookup_type(handle_ptr, "fixnum");
    try std.testing.expect(fixnum_type != null);

    const value: i64 = 99;
    try std.testing.expectEqual(ONEZ_OK, onez_register_method(
        handle_ptr,
        "inspect",
        fixnum_type,
        null,
        constantHostCallback,
        @constCast(&value),
    ));

    // Push a fixnum and call inspect, which should invoke our callback
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "inspect", 7));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);
    try std.testing.expectEqual(@as(usize, 1), test_host_callback_invocations);
}

test "register_method binary method invoked via dispatch" {
    resetHostCallbackTestState();

    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const fixnum_type = onez_lookup_type(handle_ptr, "fixnum");
    try std.testing.expect(fixnum_type != null);

    // register a binary method on + for (fixnum, fixnum) that returns a constant
    const value: i64 = 777;
    try std.testing.expectEqual(ONEZ_OK, onez_register_method(
        handle_ptr,
        "+",
        fixnum_type,
        fixnum_type,
        constantHostCallback,
        @constCast(&value),
    ));

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 1));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 2));
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "+", 1));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 777), out);
}

test "register_method rejects null arguments" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 1;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_register_method(
        null,
        "inspect",
        null,
        null,
        constantHostCallback,
        @constCast(&value),
    ));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_register_method(
        handle_ptr,
        null,
        null,
        null,
        constantHostCallback,
        @constCast(&value),
    ));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_register_method(
        handle_ptr,
        "inspect",
        null,
        null,
        null,
        @constCast(&value),
    ));
}

test "register_method returns WORD_NOT_FOUND for unknown word" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const value: i64 = 1;
    try std.testing.expectEqual(ONEZ_ERR_WORD_NOT_FOUND, onez_register_method(
        handle_ptr,
        "nonexistent-word-xyz",
        null,
        null,
        constantHostCallback,
        @constCast(&value),
    ));
}

test "register_method passes user_data to callback" {
    resetHostCallbackTestState();

    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const fixnum_type = onez_lookup_type(handle_ptr, "fixnum");
    try std.testing.expect(fixnum_type != null);

    test_host_callback_expected_handle = handle_ptr;
    const value: i64 = 42;
    try std.testing.expectEqual(ONEZ_OK, onez_register_method(
        handle_ptr,
        "inspect",
        fixnum_type,
        null,
        constantHostCallback,
        @constCast(&value),
    ));

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 0));
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "inspect", 7));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
    try std.testing.expect(test_host_callback_seen_handle == test_host_callback_expected_handle);
}

// =============================================================================
// Eval Modes: Foundation
// =============================================================================

test "init_no_prelude returns non-null handle" {
    const handle_ptr = onez_init_no_prelude();
    try std.testing.expect(handle_ptr != null);
    onez_deinit(handle_ptr);
}

test "init_no_prelude: native primitives work without prelude" {
    const handle_ptr = onez_init_no_prelude();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "1 2 +", 5));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

test "init_no_prelude: prelude-only words are unavailable" {
    const handle_ptr = onez_init_no_prelude();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const rc = onez_eval(handle_ptr, "1 2 bi", 6);
    try std.testing.expect(rc != ONEZ_OK);
}

test "load_prelude with null loads embedded prelude" {
    const handle_ptr = onez_init_no_prelude();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_load_prelude(handle_ptr, null));

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "1 2 +", 5));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

test "load_prelude with invalid path returns LOAD_FAILED" {
    const handle_ptr = onez_init_no_prelude();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_LOAD_FAILED, onez_load_prelude(handle_ptr, "/nonexistent/prelude.1z"));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "load_prelude with null handle returns NULL_HANDLE" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_load_prelude(null, null));
}

test "onez_init equals init_no_prelude + load_prelude" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "1 2 +", 5));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

test "eval_file with null path returns error" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_eval_file(handle_ptr, null));
}

test "eval_file with nonexistent path returns LOAD_FAILED" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_LOAD_FAILED, onez_eval_file(handle_ptr, "/no/such/file.1z"));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "eval_file with null handle returns NULL_HANDLE" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_eval_file(null, null));
}

test "eval_file executes file contents" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tmp_path = "/private/tmp/claude-501/capi_eval_file_test.1z";
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    tmp_file.writeAll("1 2 +\n") catch return;
    tmp_file.close();

    try std.testing.expectEqual(ONEZ_OK, onez_eval_file(handle_ptr, tmp_path));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

test "eval_file does not create a module" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tmp_path = "/private/tmp/claude-501/capi_eval_file_no_module.1z";
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    tmp_file.writeAll("42\n") catch return;
    tmp_file.close();

    try std.testing.expectEqual(ONEZ_OK, onez_eval_file(handle_ptr, tmp_path));

    // Stack should have the fixnum 42, not a module value
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_stack_type(handle_ptr, 0));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

// =============================================================================
// Eval Modes: Isolation
// =============================================================================

test "isolation_begin null handle returns NULL_HANDLE" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_isolation_begin(null));
}

test "isolation_end null handle returns NULL_HANDLE" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_isolation_end(null));
}

test "isolation_end without begin returns underflow" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_ISOLATION_UNDERFLOW, onez_isolation_end(handle_ptr));
}

test "isolation preserves stack values across boundary" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    try std.testing.expectEqual(ONEZ_OK, onez_isolation_begin(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 99));
    try std.testing.expectEqual(ONEZ_OK, onez_isolation_end(handle_ptr));

    try std.testing.expectEqual(@as(usize, 2), onez_stack_depth(handle_ptr));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "isolation discards type registrations" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_isolation_begin(handle_ptr));

    // Define a virtual type and use its constructor inside isolation.
    const define_code = "iso-color: virtual{ string } ;";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, define_code, define_code.len));
    const inside_code = "\"red\" >iso-color drop";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, inside_code, inside_code.len));

    try std.testing.expectEqual(ONEZ_OK, onez_isolation_end(handle_ptr));

    // After isolation, the constructor should no longer find its type descriptor.
    const outside_code = "\"red\" >iso-color";
    try std.testing.expect(onez_eval(handle_ptr, outside_code, outside_code.len) != ONEZ_OK);
}

test "isolation discards dispatch entries" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // Define a generic word at the top level.
    const generic_code = "iso-op: generic ( a -- b ) [ ] ;";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, generic_code, generic_code.len));

    try std.testing.expectEqual(ONEZ_OK, onez_isolation_begin(handle_ptr));

    // Register a method inside isolation and verify it dispatches.
    const method_code = "iso-op: method{ fixnum } [ 1 + ] ; 42 iso-op";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, method_code, method_code.len));
    var inside_out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &inside_out));
    try std.testing.expectEqual(@as(i64, 43), inside_out);

    try std.testing.expectEqual(ONEZ_OK, onez_isolation_end(handle_ptr));

    // After isolation, dispatch should fail (no method for fixnum).
    const outside_code = "42 iso-op";
    try std.testing.expect(onez_eval(handle_ptr, outside_code, outside_code.len) != ONEZ_OK);
}

test "eval_isolated executes code and isolates" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval_isolated(handle_ptr, code, code.len));

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

test "eval_isolated cleans up frames on eval error" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "nonexistent-word-xyz";
    try std.testing.expect(onez_eval_isolated(handle_ptr, code, code.len) != ONEZ_OK);

    // The end ran inside eval_isolated; calling end again must underflow.
    try std.testing.expectEqual(ONEZ_ERR_ISOLATION_UNDERFLOW, onez_isolation_end(handle_ptr));
}

test "isolation nests" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_isolation_begin(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_isolation_begin(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_isolation_end(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_isolation_end(handle_ptr));
    try std.testing.expectEqual(ONEZ_ERR_ISOLATION_UNDERFLOW, onez_isolation_end(handle_ptr));
}

// =============================================================================
// Eval Modes: Static analysis
// =============================================================================

test "check with null handle returns NULL_HANDLE" {
    const src = "";
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_check(null, src, src.len));
}

test "check on clean code returns OK with zero diagnostics" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-clean";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    const src = "dbl: ( n -- n ) [ 2 * ] ;";
    try std.testing.expectEqual(ONEZ_OK, onez_check(handle_ptr, src, src.len));
    try std.testing.expectEqual(@as(usize, 0), onez_diag_count(handle_ptr));
}

test "check on arity-mismatched definition reports error diagnostic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-arity";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    // Declared to leave one value on the stack but leaves none.
    const src = "bad: ( -- n ) [ ] ;";
    try std.testing.expectEqual(@as(c_int, 1), onez_check(handle_ptr, src, src.len));

    try std.testing.expect(onez_diag_count(handle_ptr) > 0);
    try std.testing.expectEqual(@as(c_int, ONEZ_DIAG_ERROR), onez_diag_severity(handle_ptr, 0));
}

test "check diagnostic accessors return expected fields" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-accessors";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    const src = "bad: ( -- n ) [ ] ;";
    try std.testing.expectEqual(@as(c_int, 1), onez_check(handle_ptr, src, src.len));
    try std.testing.expect(onez_diag_count(handle_ptr) > 0);

    try std.testing.expect(onez_diag_message(handle_ptr, 0) != null);
    try std.testing.expect(onez_diag_word(handle_ptr, 0) != null);

    const source_ptr = onez_diag_source(handle_ptr, 0);
    try std.testing.expect(source_ptr != null);
    const source_slice = std.mem.span(source_ptr.?);
    try std.testing.expectEqualStrings(tag, source_slice);

    try std.testing.expect(onez_diag_line(handle_ptr, 0) > 0);
}

test "check honors type-check warning pragma" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-warning";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    const src =
        "pragma{ type-check: \"warning\" }\n" ++
        "pragma{ suppress-undeclared: t }\n" ++
        "typed-add: ( n: fixnum -- m ) [ 1 + ] ;\n" ++
        "bad-caller: ( -- ) [ \"hello\" typed-add drop ] ;\n";

    // Warning-only: return code is OK.
    try std.testing.expectEqual(ONEZ_OK, onez_check(handle_ptr, src, src.len));

    const count = onez_diag_count(handle_ptr);
    try std.testing.expect(count > 0);

    var saw_warning = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (onez_diag_severity(handle_ptr, i) == ONEZ_DIAG_WARNING) saw_warning = true;
    }
    try std.testing.expect(saw_warning);
}

test "check clears prior diagnostics on repeated call" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-repeat";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    const bad_src = "bad: ( -- n ) [ ] ;";
    try std.testing.expectEqual(@as(c_int, 1), onez_check(handle_ptr, bad_src, bad_src.len));
    try std.testing.expect(onez_diag_count(handle_ptr) > 0);

    // Use a fresh source name so the second check only analyzes the clean word.
    const tag2 = "check-repeat-clean";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag2, tag2.len));

    const good_src = "good: ( n -- n ) [ 1 + ] ;";
    try std.testing.expectEqual(ONEZ_OK, onez_check(handle_ptr, good_src, good_src.len));
    try std.testing.expectEqual(@as(usize, 0), onez_diag_count(handle_ptr));
}

test "check out-of-range accessors return documented fallbacks" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-oor";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    // Start from a clean state; diagnostics list is empty.
    try std.testing.expectEqual(@as(usize, 0), onez_diag_count(handle_ptr));

    try std.testing.expectEqual(@as(c_int, -1), onez_diag_severity(handle_ptr, 0));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_diag_message(handle_ptr, 0));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_diag_source(handle_ptr, 0));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_diag_word(handle_ptr, 0));
    try std.testing.expectEqual(@as(usize, 0), onez_diag_line(handle_ptr, 0));
}

test "check accessors with null handle return fallbacks" {
    try std.testing.expectEqual(@as(usize, 0), onez_diag_count(null));
    try std.testing.expectEqual(@as(c_int, -1), onez_diag_severity(null, 0));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_diag_message(null, 0));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_diag_source(null, 0));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_diag_word(null, 0));
    try std.testing.expectEqual(@as(usize, 0), onez_diag_line(null, 0));
}

test "check with parse error reports via last_error, not diagnostics" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-parse-error";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    // Mismatched bracket -- the parser should reject this.
    const src = "oops: ( -- ) [ [ ] ;";
    try std.testing.expectEqual(@as(c_int, 1), onez_check(handle_ptr, src, src.len));

    try std.testing.expect(onez_last_error(handle_ptr) != null);
    try std.testing.expectEqual(@as(usize, 0), onez_diag_count(handle_ptr));
}

test "check diagnostics survive intervening eval" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const tag = "check-survives";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, tag, tag.len));

    const src = "bad: ( -- n ) [ ] ;";
    try std.testing.expectEqual(@as(c_int, 1), onez_check(handle_ptr, src, src.len));

    const count_before = onez_diag_count(handle_ptr);
    try std.testing.expect(count_before > 0);

    // Snapshot message pointer and content before the eval.
    const msg_before_ptr = onez_diag_message(handle_ptr, 0);
    try std.testing.expect(msg_before_ptr != null);
    const msg_before_copy = try std.testing.allocator.dupe(u8, std.mem.span(msg_before_ptr.?));
    defer std.testing.allocator.free(msg_before_copy);

    // onez_eval does not clear the diagnostics list.
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "1 2 +", 5));

    try std.testing.expectEqual(count_before, onez_diag_count(handle_ptr));
    const msg_after_ptr = onez_diag_message(handle_ptr, 0);
    try std.testing.expect(msg_after_ptr != null);
    try std.testing.expectEqualStrings(msg_before_copy, std.mem.span(msg_after_ptr.?));

    // Drain the stack so deinit sees a clean slate.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

// =========================================================================
// Debugger tests
// =========================================================================

test "debug stepping APIs return DEBUGGER_NOT_ACTIVE before enable" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_debug_step_into(handle_ptr));
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_debug_step_over(handle_ptr));
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_debug_step_finish(handle_ptr));
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_debug_continue(handle_ptr));
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_debug_disable(handle_ptr));
}

test "debug enable and disable lifecycle" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_step_into(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_disable(handle_ptr));

    // After disable, stepping fails again.
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_debug_step_into(handle_ptr));

    // Re-enable works -- the debugger instance is preserved.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_step_into(handle_ptr));
}

test "debug null handle returns NULL_HANDLE" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_debug_enable(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_debug_disable(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_debug_step_into(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_debug_step_over(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_debug_step_finish(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_debug_continue(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_debug_set_callback(null, null, null));
}

var test_debug_event_count: usize = 0;
var test_debug_last_event: c_int = -1;
var test_debug_seen_handle: ?*anyopaque = null;

fn resetDebugTestState() void {
    test_debug_event_count = 0;
    test_debug_last_event = -1;
    test_debug_seen_handle = null;
}

fn debugTestCallback(event: c_int, handle: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    test_debug_event_count += 1;
    test_debug_last_event = event;
    test_debug_seen_handle = handle;

    // On pause, set continue so execution doesn't stay in step_into forever.
    if (event == ONEZ_EVENT_PAUSED) {
        _ = onez_debug_continue(handle);
    }
}

test "debug callback fires during eval" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetDebugTestState();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &debugTestCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    // step_into is the default mode, so the first instruction will pause.
    const src = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // The callback should have been invoked at least once with a paused event.
    try std.testing.expect(test_debug_event_count > 0);
    try std.testing.expectEqual(handle_ptr, test_debug_seen_handle);

    // Drain the stack.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

var test_debug_step_into_pauses: usize = 0;

fn debugStepIntoCallback(event: c_int, handle: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (event == ONEZ_EVENT_PAUSED) {
        test_debug_step_into_pauses += 1;
        // Keep stepping into so we pause on every instruction.
        _ = onez_debug_step_into(handle);
    }
}

test "debug step_into pauses on every instruction" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    test_debug_step_into_pauses = 0;

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &debugStepIntoCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    // "1 2 +" has 3 instructions (push 1, push 2, call +).
    const src = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // Should pause at least 3 times (one per instruction in the top-level quotation).
    try std.testing.expect(test_debug_step_into_pauses >= 3);

    // Drain the stack.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

test "debug set_callback before enable wires up on enable" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetDebugTestState();

    // Set callback BEFORE enable.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &debugTestCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const src = "1";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    try std.testing.expect(test_debug_event_count > 0);

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

test "debug re-enable after disable preserves callback" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetDebugTestState();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &debugTestCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_disable(handle_ptr));

    // Re-enable.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const src = "1";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    try std.testing.expect(test_debug_event_count > 0);

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

// Event sequence tracking for event-order tests.
const max_tracked_events = 64;
var tracked_events: [max_tracked_events]c_int = undefined;
var tracked_event_count: usize = 0;

fn resetTrackedEvents() void {
    tracked_event_count = 0;
}

fn trackingCallback(event: c_int, handle: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (tracked_event_count < max_tracked_events) {
        tracked_events[tracked_event_count] = event;
        tracked_event_count += 1;
    }
    // Continue on pause so execution proceeds.
    if (event == ONEZ_EVENT_PAUSED) {
        _ = onez_debug_continue(handle);
    }
}

test "debug callback receives RESUMED after PAUSED" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetTrackedEvents();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &trackingCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const src = "1";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // Should have at least PAUSED, RESUMED, STEP_COMPLETED.
    try std.testing.expect(tracked_event_count >= 3);

    // Find the first PAUSED and verify RESUMED follows it.
    var found_paused = false;
    for (0..tracked_event_count - 1) |i| {
        if (tracked_events[i] == ONEZ_EVENT_PAUSED) {
            found_paused = true;
            try std.testing.expectEqual(ONEZ_EVENT_RESUMED, tracked_events[i + 1]);
            break;
        }
    }
    try std.testing.expect(found_paused);

    // Drain.
    var out_val: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out_val));
}

test "debug callback receives STEP_COMPLETED" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetTrackedEvents();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &trackingCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const src = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // Verify STEP_COMPLETED appears in the event stream.
    var found_step_completed = false;
    for (0..tracked_event_count) |i| {
        if (tracked_events[i] == ONEZ_EVENT_STEP_COMPLETED) {
            found_step_completed = true;
            break;
        }
    }
    try std.testing.expect(found_step_completed);

    // Verify event triplet pattern: PAUSED -> RESUMED -> STEP_COMPLETED.
    var found_triplet = false;
    if (tracked_event_count >= 3) {
        for (0..tracked_event_count - 2) |i| {
            if (tracked_events[i] == ONEZ_EVENT_PAUSED and
                tracked_events[i + 1] == ONEZ_EVENT_RESUMED and
                tracked_events[i + 2] == ONEZ_EVENT_STEP_COMPLETED)
            {
                found_triplet = true;
                break;
            }
        }
    }
    try std.testing.expect(found_triplet);

    // Drain.
    var out_val: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out_val));
}

// =========================================================================
// Breakpoint tests
// =========================================================================

// Callback that tracks BREAKPOINT_HIT events and continues.
var bp_hit_count: usize = 0;

fn resetBpTestState() void {
    bp_hit_count = 0;
    resetTrackedEvents();
}

fn bpTrackingCallback(event: c_int, handle: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (event == ONEZ_EVENT_BREAKPOINT_HIT) {
        bp_hit_count += 1;
    }
    if (tracked_event_count < max_tracked_events) {
        tracked_events[tracked_event_count] = event;
        tracked_event_count += 1;
    }
    if (event == ONEZ_EVENT_PAUSED) {
        _ = onez_debug_continue(handle);
    }
}

test "breakpoint APIs return DEBUGGER_NOT_ACTIVE before enable" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // add functions return 0 when debugger is not active.
    try std.testing.expectEqual(@as(u32, 0), onez_breakpoint_add_word(handle_ptr, "+"));
    const f = "test.1z";
    try std.testing.expectEqual(@as(u32, 0), onez_breakpoint_add_source(handle_ptr, f, f.len, 1));
    try std.testing.expectEqual(@as(u32, 0), onez_breakpoint_add_conditional(handle_ptr, "+", "t"));

    // Management functions return error code.
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_breakpoint_enable(handle_ptr, 1));
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_breakpoint_disable(handle_ptr, 1));
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_breakpoint_delete(handle_ptr, 1));
}

test "breakpoint enable/disable/delete lifecycle" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const id = onez_breakpoint_add_word(handle_ptr, "dup");
    try std.testing.expect(id >= 1);

    try std.testing.expectEqual(ONEZ_OK, onez_breakpoint_disable(handle_ptr, id));
    try std.testing.expectEqual(ONEZ_OK, onez_breakpoint_enable(handle_ptr, id));
    try std.testing.expectEqual(ONEZ_OK, onez_breakpoint_delete(handle_ptr, id));

    // Second delete fails: breakpoint no longer exists.
    try std.testing.expectEqual(ONEZ_ERR_BREAKPOINT_NOT_FOUND, onez_breakpoint_delete(handle_ptr, id));

    // Enable/disable also fail for deleted breakpoint.
    try std.testing.expectEqual(ONEZ_ERR_BREAKPOINT_NOT_FOUND, onez_breakpoint_enable(handle_ptr, id));
    try std.testing.expectEqual(ONEZ_ERR_BREAKPOINT_NOT_FOUND, onez_breakpoint_disable(handle_ptr, id));
}

test "breakpoint add_word triggers BREAKPOINT_HIT on matching word" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetBpTestState();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &bpTrackingCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const id = onez_breakpoint_add_word(handle_ptr, "+");
    try std.testing.expect(id >= 1);

    // Set continue mode so we don't pause on every instruction before
    // hitting the breakpoint.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_continue(handle_ptr));

    const src = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // The "+" word should have triggered BREAKPOINT_HIT.
    try std.testing.expect(bp_hit_count >= 1);

    // Verify BREAKPOINT_HIT appears in the event stream.
    var found = false;
    for (0..tracked_event_count) |i| {
        if (tracked_events[i] == ONEZ_EVENT_BREAKPOINT_HIT) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

test "breakpoint persists across disable/enable cycle" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetBpTestState();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &bpTrackingCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const id = onez_breakpoint_add_word(handle_ptr, "+");
    try std.testing.expect(id >= 1);

    // Disable and re-enable the debugger.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_disable(handle_ptr));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    // Set continue so we run to the breakpoint.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_continue(handle_ptr));

    const src = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // Breakpoint should still fire after re-enable.
    try std.testing.expect(bp_hit_count >= 1);

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

test "breakpoint add_source triggers at file and line" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetBpTestState();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &bpTrackingCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    // Source breakpoints match on ctx.current_source and instruction line.
    // onez_eval sets current_source to "<eval>".
    const source = "<eval>";
    const id = onez_breakpoint_add_source(handle_ptr, source, source.len, 1);
    try std.testing.expect(id >= 1);

    // Set continue so we run to the breakpoint.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_continue(handle_ptr));

    const src = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    try std.testing.expect(bp_hit_count >= 1);

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

test "breakpoint add_conditional triggers when condition is true" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    resetBpTestState();

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &bpTrackingCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    // Break on "+" only when top of stack is > 2.
    const id = onez_breakpoint_add_conditional(handle_ptr, "+", "dup 2 >");
    try std.testing.expect(id >= 1);

    // Set continue so we run to the breakpoint.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_continue(handle_ptr));

    // "1 2 +" -- top of stack when "+" executes is 2, not > 2, so no hit.
    const src1 = "1 2 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src1, src1.len));
    try std.testing.expectEqual(@as(usize, 0), bp_hit_count);

    // Drain result of first eval.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));

    // "1 3 +" -- top of stack when "+" executes is 3, which is > 2.
    try std.testing.expectEqual(ONEZ_OK, onez_debug_continue(handle_ptr));
    const src2 = "1 3 +";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src2, src2.len));
    try std.testing.expect(bp_hit_count >= 1);

    // Drain.
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

// =========================================================================
// Debug state inspection tests
// =========================================================================

var test_inspect_current_word: ?[*:0]const u8 = null;
var test_inspect_frame_count: usize = 0;
var test_inspect_handle: ?*anyopaque = null;

fn inspectCurrentWordCallback(event: c_int, handle: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (event == ONEZ_EVENT_PAUSED) {
        test_inspect_current_word = onez_debug_current_word(handle);
        test_inspect_frame_count = onez_debug_frame_count(handle);
        test_inspect_handle = handle;
        // Continue to let execution finish.
        _ = onez_debug_continue(handle);
    }
}

test "debug current_word returns word name during callback" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    test_inspect_current_word = null;
    test_inspect_frame_count = 0;

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &inspectCurrentWordCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    // Define a word "my-add" and call it. When the debugger pauses inside
    // "my-add", current_word should return "my-add".
    const src = "my-add: [ + ] ; 1 2 my-add";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // The callback should have captured a non-null word name.
    try std.testing.expect(test_inspect_current_word != null);

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 3), out);
}

var test_inspect_source_file: ?[*:0]const u8 = null;
var test_inspect_source_line: c_uint = 0;
var test_inspect_source_col: c_uint = 0;
var test_inspect_source_rc: c_int = -1;

fn inspectSourceCallback(event: c_int, handle: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (event == ONEZ_EVENT_PAUSED) {
        test_inspect_source_rc = onez_debug_current_source(handle, &test_inspect_source_file, &test_inspect_source_line, &test_inspect_source_col);
        _ = onez_debug_continue(handle);
    }
}

test "debug current_source returns source info during callback" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    test_inspect_source_file = null;
    test_inspect_source_line = 0;
    test_inspect_source_col = 0;
    test_inspect_source_rc = -1;

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &inspectSourceCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    const src = "my-word: [ 42 ] ; my-word";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // current_source should have returned OK at some point during execution.
    try std.testing.expectEqual(ONEZ_OK, test_inspect_source_rc);
    try std.testing.expect(test_inspect_source_file != null);

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

var test_inspect_frame_words: [8]?[*:0]const u8 = .{null} ** 8;
var test_inspect_frame_total: usize = 0;

fn inspectFrameCallback(event: c_int, handle: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (event == ONEZ_EVENT_PAUSED) {
        const count = onez_debug_frame_count(handle);
        if (count >= 2) {
            // We're inside a nested call; capture frame info.
            test_inspect_frame_total = count;
            const n = @min(count, 8);
            for (0..n) |i| {
                test_inspect_frame_words[i] = onez_debug_frame_word(handle, i);
            }
            _ = onez_debug_continue(handle);
        } else {
            // Keep stepping until we get a deeper call stack.
            _ = onez_debug_step_into(handle);
        }
    }
}

test "debug frame_count and frame accessors" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    test_inspect_frame_total = 0;
    test_inspect_frame_words = .{null} ** 8;

    try std.testing.expectEqual(ONEZ_OK, onez_debug_set_callback(handle_ptr, &inspectFrameCallback, null));
    try std.testing.expectEqual(ONEZ_OK, onez_debug_enable(handle_ptr));

    // Define nested words so we get a multi-frame call stack.
    const src = "inner: [ 42 ] ; outer: [ inner ] ; outer";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, src, src.len));

    // We should have seen at least 2 frames (outer calling inner).
    try std.testing.expect(test_inspect_frame_total >= 2);
    // Frame 0 (innermost) should be non-null.
    try std.testing.expect(test_inspect_frame_words[0] != null);

    // Also test out-of-range returns null.
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_debug_frame_word(handle_ptr, 9999));

    // frame_line and frame_column should return -1 for out-of-range.
    try std.testing.expectEqual(@as(c_int, -1), onez_debug_frame_line(handle_ptr, 9999));
    try std.testing.expectEqual(@as(c_int, -1), onez_debug_frame_column(handle_ptr, 9999));

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

test "stack_peek reads without popping" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // Push two values.
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 10));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 20));

    // Peek at top (index 0).
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_stack_peek(handle_ptr, 0, &val_handle));
    try std.testing.expect(val_handle != null);
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(val_handle));

    // Stack depth should still be 2.
    try std.testing.expectEqual(@as(usize, 2), onez_stack_depth(handle_ptr));

    // Peek at index 1 (second from top).
    var val_handle2: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_stack_peek(handle_ptr, 1, &val_handle2));
    try std.testing.expect(val_handle2 != null);

    // Stack depth unchanged.
    try std.testing.expectEqual(@as(usize, 2), onez_stack_depth(handle_ptr));

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 20), out);
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 10), out);
}

test "stack_peek out of range returns error" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // Empty stack -- peek should fail.
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_INDEX_OUT_OF_RANGE, onez_stack_peek(handle_ptr, 0, &val_handle));

    // Push one value, peek at index 1 should fail.
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    try std.testing.expectEqual(ONEZ_ERR_INDEX_OUT_OF_RANGE, onez_stack_peek(handle_ptr, 1, &val_handle));

    // Peek at index 0 should succeed.
    try std.testing.expectEqual(ONEZ_OK, onez_stack_peek(handle_ptr, 0, &val_handle));

    // Drain.
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
}

test "debug inspection APIs return defaults before enable" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // current_word returns null when debugger not active.
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_debug_current_word(handle_ptr));

    // current_source returns DEBUGGER_NOT_ACTIVE.
    var file: ?[*:0]const u8 = null;
    var line: c_uint = 0;
    var col: c_uint = 0;
    try std.testing.expectEqual(ONEZ_ERR_DEBUGGER_NOT_ACTIVE, onez_debug_current_source(handle_ptr, &file, &line, &col));

    // frame_count returns 0.
    try std.testing.expectEqual(@as(usize, 0), onez_debug_frame_count(handle_ptr));

    // frame accessors return null / -1.
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_debug_frame_word(handle_ptr, 0));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_debug_frame_file(handle_ptr, 0));
    try std.testing.expectEqual(@as(c_int, -1), onez_debug_frame_line(handle_ptr, 0));
    try std.testing.expectEqual(@as(c_int, -1), onez_debug_frame_column(handle_ptr, 0));

    // local_count returns 0.
    try std.testing.expectEqual(@as(usize, 0), onez_debug_local_count(handle_ptr));

    // local accessors return null / -1.
    try std.testing.expectEqual(@as(?[*:0]const u8, null), onez_debug_local_name(handle_ptr, 0));
    try std.testing.expectEqual(@as(c_int, -1), onez_debug_local_kind(handle_ptr, 0));
}
