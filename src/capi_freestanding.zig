const std = @import("std");
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .page_size_min = 4096,
};

pub const panic = std.debug.no_panic;

const ONEZ_OK: c_int = 0;
const ONEZ_ERR_NULL_HANDLE: c_int = -1;
const ONEZ_ERR_LOAD_FAILED: c_int = 6;

const freestanding_heap_size: usize = @as(usize, build_options.freestanding_heap_mib) << 20;
const freestanding_stack_bytes = 64 * 1024;
const freestanding_stack_slots = 1024;
var freestanding_heap_buf: [freestanding_heap_size]u8 align(16) = undefined;
var freestanding_fba = std.heap.FixedBufferAllocator.init(&freestanding_heap_buf);
var freestanding_handle: ?OnezHandle = null;

const OnezWordFn = *const fn (*JitContext) callconv(.c) i32;

const OnezHandle = struct {
    allocator: std.mem.Allocator,
    dispatch_table: []?OnezWordFn = &.{},
    quotation_table: []?OnezWordFn = &.{},
    word_names: []?[*:0]const u8 = &.{},
    stack_bytes: []align(16) u8 = &.{},
    stack_len: usize = 0,
    last_error: ?[:0]const u8 = null,
    interpreter_fallback_allowed: bool = false,
};

pub const JitContext = extern struct {
    items_ptr: [*]u8,
    sp_ptr: *usize,
    capacity: usize,
    ctx: *anyopaque,
    trampoline_target: u32 = 0,
};

fn allocator() std.mem.Allocator {
    return freestanding_fba.allocator();
}

fn castHandle(ptr: ?*anyopaque) ?*OnezHandle {
    const raw = ptr orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn clearLastError(handle: *OnezHandle) void {
    if (handle.last_error) |msg| handle.allocator.free(msg);
    handle.last_error = null;
}

fn setLastError(handle: *OnezHandle, comptime fmt: []const u8, args: anytype) void {
    clearLastError(handle);
    handle.last_error = std.fmt.allocPrintSentinel(handle.allocator, fmt, args, 0) catch null;
}

fn unsupported(handle: ?*OnezHandle, comptime name: []const u8) i32 {
    if (handle) |h| setLastError(h, "{s} is not available on this build", .{name});
    return 1;
}

export fn onez_init_no_prelude() ?*anyopaque {
    if (freestanding_handle) |*existing| return existing;

    const alloc = allocator();
    const stack = alloc.alignedAlloc(u8, .fromByteUnits(16), freestanding_stack_bytes) catch return null;
    freestanding_handle = .{
        .allocator = alloc,
        .stack_bytes = stack,
    };
    return &freestanding_handle.?;
}

export fn onez_init() ?*anyopaque {
    return onez_init_no_prelude();
}

export fn onez_deinit(ptr: ?*anyopaque) void {
    const handle = castHandle(ptr) orelse return;
    clearLastError(handle);
}

export fn onez_set_error(ptr: ?*anyopaque, msg: ?[*]const u8, len: usize) void {
    const handle = castHandle(ptr) orelse return;
    const p = msg orelse return;
    setLastError(handle, "{s}", .{p[0..len]});
}

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
    _ = header_ptr;
    _ = typevalue_slots_ptr;
    _ = struct_type_slots_ptr;
    _ = marker_slots_ptr;
    _ = parameter_slots_ptr;
    _ = tagged_slots_ptr;
    _ = mutable_map_slots_ptr;
    _ = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    return ONEZ_OK;
}

export fn onez_runtime_register_compiled(ptr: ?*anyopaque, table: [*]const ?*const anyopaque, names: [*]const ?[*:0]const u8, size: u32) i32 {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const n: usize = @intCast(size);

    const dispatch = handle.allocator.alloc(?OnezWordFn, n) catch return ONEZ_ERR_LOAD_FAILED;
    const word_names = handle.allocator.alloc(?[*:0]const u8, n) catch return ONEZ_ERR_LOAD_FAILED;
    for (0..n) |i| {
        dispatch[i] = if (table[i]) |code_ptr| @ptrCast(@alignCast(code_ptr)) else null;
        word_names[i] = names[i];
    }

    handle.dispatch_table = dispatch;
    handle.word_names = word_names;
    return ONEZ_OK;
}

export fn onez_runtime_register_quotations(ptr: ?*anyopaque, table: [*]const ?*const anyopaque, size: u32) i32 {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const n: usize = @intCast(size);

    const quotations = handle.allocator.alloc(?OnezWordFn, n) catch return ONEZ_ERR_LOAD_FAILED;
    for (0..n) |i| {
        quotations[i] = if (table[i]) |code_ptr| @ptrCast(@alignCast(code_ptr)) else null;
    }

    handle.quotation_table = quotations;
    return ONEZ_OK;
}

export fn onez_runtime_run(ptr: ?*anyopaque, entry_word_id: u32) i32 {
    const handle = castHandle(ptr) orelse return 1;
    if (entry_word_id >= handle.dispatch_table.len) return unsupported(handle, "entry word");
    var code_ptr = handle.dispatch_table[entry_word_id] orelse return unsupported(handle, "entry word");

    var jit_ctx = JitContext{
        .items_ptr = handle.stack_bytes.ptr,
        .sp_ptr = &handle.stack_len,
        .capacity = freestanding_stack_slots,
        .ctx = handle,
    };
    var status = code_ptr(&jit_ctx);

    while (status == 3) {
        const target = jit_ctx.trampoline_target;
        if (target >= handle.dispatch_table.len) return unsupported(handle, "tail-call target");
        code_ptr = handle.dispatch_table[target] orelse return unsupported(handle, "tail-call target");
        jit_ctx.items_ptr = handle.stack_bytes.ptr;
        jit_ctx.capacity = freestanding_stack_slots;
        status = code_ptr(&jit_ctx);
    }

    return if (status == 0) 0 else 1;
}

export fn onez_set_interpreter_fallback(ptr: ?*anyopaque, allowed: bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.interpreter_fallback_allowed = allowed;
    return ONEZ_OK;
}

export fn onez_print_error(ptr: ?*anyopaque) void {
    _ = ptr;
}

export fn onez_set_args(ptr: ?*anyopaque, argc: c_int, argv: [*]const [*:0]const u8) c_int {
    _ = ptr;
    _ = argc;
    _ = argv;
    return ONEZ_OK;
}

export fn onez_set_static_libs(ptr: ?*anyopaque, names: [*]const [*:0]const u8, count: u32) c_int {
    _ = ptr;
    _ = names;
    _ = count;
    return ONEZ_ERR_LOAD_FAILED;
}

export fn jitCallCodePtr(jit_ctx_raw: usize, code_ptr_raw: usize) callconv(.c) i32 {
    if (code_ptr_raw == 0) return 1;
    const func: *const fn (usize) callconv(.c) i32 = @ptrFromInt(code_ptr_raw);
    return func(jit_ctx_raw);
}

export fn jitRefreshStack(jit_ctx_raw: usize) callconv(.c) i32 {
    if (jit_ctx_raw == 0) return 0;
    const jc: *JitContext = @ptrFromInt(jit_ctx_raw);
    const handle: *OnezHandle = @ptrCast(@alignCast(jc.ctx));
    jc.items_ptr = handle.stack_bytes.ptr;
    jc.capacity = freestanding_stack_slots;
    return 0;
}

export fn jitEnsureStackCapacity(jit_ctx_raw: usize, needed: usize) callconv(.c) i32 {
    if (jit_ctx_raw == 0) return 2;
    const jc: *JitContext = @ptrFromInt(jit_ctx_raw);
    if (needed <= jc.capacity) return 0;
    return 2;
}

fn unsupportedJit() i32 {
    return 1;
}

export fn jitRetainSlot(value_ptr: usize) callconv(.c) i32 {
    _ = value_ptr;
    return 0;
}

export fn jitReleaseSlot(value_ptr: usize) callconv(.c) i32 {
    _ = value_ptr;
    return 0;
}

export fn jitPushString(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = str_ptr;
    _ = str_len;
    return unsupportedJit();
}

export fn jitPushSymbol(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = str_ptr;
    _ = str_len;
    return unsupportedJit();
}

export fn jitPushQuotation(ctx_raw: usize, data_ptr: usize, data_len: usize, dest_raw: usize, quotation_id: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = data_ptr;
    _ = data_len;
    _ = dest_raw;
    _ = quotation_id;
    return unsupportedJit();
}

export fn jitPushArray(ctx_raw: usize, data_ptr: usize, data_len: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = data_ptr;
    _ = data_len;
    return unsupportedJit();
}

export fn jitPushTypeValueSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = slot;
    return unsupportedJit();
}

export fn jitPushStructTypeSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = slot;
    return unsupportedJit();
}

export fn jitPushMarkerSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = slot;
    return unsupportedJit();
}

export fn jitPushParameterSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = slot;
    return unsupportedJit();
}

export fn jitPushTaggedSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = slot;
    return unsupportedJit();
}

export fn jitPushMutableMapSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = slot;
    return unsupportedJit();
}

export fn jitCallQuotation(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return unsupportedJit();
}

export fn jitInterpretedCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = word_id_raw;
    _ = line_raw;
    return unsupportedJit();
}

export fn jitNativeWordCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    _ = word_id_raw;
    _ = line_raw;
    return unsupportedJit();
}

export fn jitOverflowError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}

export fn jitDivisionByZeroError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}

export fn jitStackUnderflowError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}

export fn jitTypeMismatchError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}
