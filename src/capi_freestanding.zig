const std = @import("std");
const build_options = @import("build_options");

const BigIntManaged = opaque {};
const HashTable = opaque {};
const Vector = opaque {};
const ByteArray = opaque {};
const Set = opaque {};
const MutableMap = opaque {};
const StreamMode = enum {
    read,
    write,
    append,
    read_write,
};

const BufferingMode = enum {
    none,
    line,
    block,
};

const StreamVTable = struct {
    read: *const fn (*Stream, []u8) anyerror!usize,
    write: *const fn (*Stream, []const u8) anyerror!usize,
    close: *const fn (*Stream) void,
    flush: *const fn (*Stream) anyerror!void,
};

const Stream = struct {
    vtable: *const StreamVTable,
    fd: i32 = -1,
    mode: StreamMode,
    closed: bool = false,
    name: []const u8,
    buffering: BufferingMode = .none,
    nonblocking_set: bool = false,
    impl: ?*anyopaque = null,
    inner: ?*Stream = null,
};
const Resource = opaque {};
const Parameter = struct {
    name: []const u8,
    default_quotation: Quotation,
};
const Module = opaque {};
const Marker = opaque {};
const StructType = opaque {};
const StructInstance = opaque {};
const VirtualType = opaque {};
const TypeValue = opaque {};
const TypeDescriptor = opaque {};
const ProtocolDescriptor = opaque {};
const ConstraintCombinator = opaque {};
const BenchmarkReportHandle = opaque {};
const ErrorObject = opaque {};
const Task = opaque {};
const Channel = opaque {};
const Iterator = opaque {};
const SandboxSpec = opaque {};
const WordSlot = opaque {};

const StackEffect = struct {
    inputs: []const StackEffectParam,
    outputs: []const StackEffectParam,
};

const TypeAnnotation = union(enum) {
    type: *const TypeValue,
    protocol: *const ProtocolDescriptor,
};

const StackEffectParam = struct {
    name: []const u8,
    quotation_effect: ?*const StackEffect = null,
    is_row_variable: bool = false,
    type_annotation: ?TypeAnnotation = null,
};

const Instruction = struct {
    op: Op,
    line: usize,
    column: usize = 0,

    const Op = union(enum) {
        push_literal: Value,
        call_word: []const u8,
        call_word_direct: *WordSlot,
    };
};

const FormatSpec = struct {
    width: ?usize = null,
    fill: u8 = ' ',
    align_left: bool = false,
};

const TemplateSegment = union(enum) {
    literal: []const u8,
    identity: FormatSpec,
    named: struct {
        name: []const u8,
        spec: FormatSpec,
    },
    indexed: struct {
        index: usize,
        spec: FormatSpec,
    },
};

const Quotation = struct {
    instructions: []const Instruction,
    effect: ?*const StackEffect = null,
    code_ptr: ?*const anyopaque = null,
};

const ImageParameterDescription = extern struct {
    name: [*]const u8,
    name_len: u32,
    slot: u32,
    default_quotation_bytecode: ?[*]const u8,
    default_quotation_bytecode_len: u32,
};

const ImageHeader = extern struct {
    format_version: u32,
    module_count: u32,
    word_count: u32,
    marker_pool_count: u32,
    typevalue_slot_count: u32,
    stack_effect_count: u32,
    typevalue_count: u32,
    struct_type_count: u32,
    marker_slot_count: u32,
    parameter_slot_count: u32,
    tagged_slot_count: u32,
    mutable_map_slot_count: u32,
    protocoldescriptor_slot_count: u32,
    constraintcombinator_slot_count: u32,
    modules: ?*const anyopaque,
    words: ?*const anyopaque,
    markers: ?*const anyopaque,
    stack_effects: ?*const anyopaque,
    typevalues: ?*const anyopaque,
    typedescriptors: ?*const anyopaque,
    struct_types: ?*const anyopaque,
    marker_descriptions: ?*const anyopaque,
    parameter_descriptions: ?[*]const ImageParameterDescription,
    tagged_descriptions: ?*const anyopaque,
    mutable_map_descriptions: ?*const anyopaque,
    protocoldescriptor_descriptions: ?*const anyopaque,
    constraintcombinator_descriptions: ?*const anyopaque,
};

const Value = union(enum) {
    fixnum: i64,
    float: f64,
    bignum: *BigIntManaged,
    boolean: bool,
    string: []const u8,
    symbol: []const u8,
    array: []const Value,
    quotation: Quotation,
    hash: *HashTable,
    vector: *Vector,
    byte_array: *ByteArray,
    set: *Set,
    mutable_map: *MutableMap,
    stream: *Stream,
    resource: *Resource,
    parameter: *Parameter,
    module: *Module,
    marker: *Marker,
    struct_type: *StructType,
    struct_instance: *StructInstance,
    tagged: struct { tag: *const VirtualType, inner: *const Value },
    template: []const TemplateSegment,
    benchmark_report: *BenchmarkReportHandle,
    stack_effect: StackEffect,
    error_value: *ErrorObject,
    task: *Task,
    channel: *Channel,
    iterator: *Iterator,
    doc_string: []const u8,
    type_val: *TypeValue,
    type_descriptor: *const TypeDescriptor,
    protocol_descriptor: *const ProtocolDescriptor,
    constraint_combinator: *const ConstraintCombinator,
    sandbox_spec: *SandboxSpec,
    unit: void,
};

pub const std_options: std.Options = .{
    .page_size_min = 4096,
};

pub const panic = std.debug.no_panic;

const ONEZ_OK: c_int = 0;
const ONEZ_ERR_NULL_HANDLE: c_int = -1;
const ONEZ_ERR_LOAD_FAILED: c_int = 6;
const ONEZ_ERR_INVALID_ARGUMENT: c_int = 7;

const output_parameter_name = "output-stream";
const WriterFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) usize;

const freestanding_heap_size: usize = @as(usize, build_options.freestanding_heap_mib) << 20;
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
    stack: []align(16) Value = &.{},
    stack_len: usize = 0,
    last_error: ?[:0]const u8 = null,
    interpreter_fallback_allowed: bool = false,
    output_writer_ctx: ?*anyopaque = null,
    output_writer: ?WriterFn = null,
    output_stream: Stream = .{
        .vtable = &freestanding_output_vtable,
        .mode = .write,
        .name = output_parameter_name,
    },
    output_parameter: Parameter = .{
        .name = output_parameter_name,
        .default_quotation = .{ .instructions = &.{} },
    },
    parameter_slots: []?*Parameter = &.{},
};

pub const JitContext = extern struct {
    items_ptr: [*]Value,
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

fn unsupportedName(handle: ?*OnezHandle, name: []const u8) i32 {
    if (handle) |h| setLastError(h, "{s} is not available on this build", .{name});
    return 1;
}

fn unsupportedJit(ctx_raw: usize, comptime name: []const u8) i32 {
    if (handleFromContext(ctx_raw)) |handle| {
        setLastError(handle, "{s} is not available on this build", .{name});
    }
    return 2;
}

fn handleFromContext(ctx_raw: usize) ?*OnezHandle {
    if (ctx_raw == 0) return null;
    const raw: *anyopaque = @ptrFromInt(ctx_raw);
    return @ptrCast(@alignCast(raw));
}

fn contextFromJit(jit_ctx_raw: usize) ?*JitContext {
    if (jit_ctx_raw == 0) return null;
    return @ptrFromInt(jit_ctx_raw);
}

fn pushValue(handle: *OnezHandle, value: Value) i32 {
    if (handle.stack_len >= handle.stack.len) {
        setLastError(handle, "value stack capacity exceeded", .{});
        return 2;
    }
    handle.stack[handle.stack_len] = value;
    handle.stack_len += 1;
    return 0;
}

fn popValue(handle: *OnezHandle) ?Value {
    if (handle.stack_len == 0) {
        setLastError(handle, "value stack underflow", .{});
        return null;
    }
    handle.stack_len -= 1;
    return handle.stack[handle.stack_len];
}

fn popStream(handle: *OnezHandle) ?*Stream {
    const value = popValue(handle) orelse return null;
    return switch (value) {
        .stream => |stream| stream,
        else => {
            setLastError(handle, "type mismatch: expected stream", .{});
            return null;
        },
    };
}

fn popWritableBytes(handle: *OnezHandle) ?[]const u8 {
    const value = popValue(handle) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => {
            setLastError(handle, "type mismatch: expected string or byte-array", .{});
            return null;
        },
    };
}

fn unsupportedRead(_: *Stream, _: []u8) anyerror!usize {
    return error.NotOpenForReading;
}

fn outputWrite(stream: *Stream, bytes: []const u8) anyerror!usize {
    const handle: *OnezHandle = @ptrCast(@alignCast(stream.impl orelse return error.NotOpenForWriting));
    const writer = handle.output_writer orelse return error.NotOpenForWriting;
    return writer(handle.output_writer_ctx, bytes.ptr, bytes.len);
}

fn outputClose(stream: *Stream) void {
    stream.closed = true;
}

fn outputFlush(_: *Stream) anyerror!void {}

const freestanding_output_vtable = StreamVTable{
    .read = unsupportedRead,
    .write = outputWrite,
    .close = outputClose,
    .flush = outputFlush,
};

fn bindOutputWriter(handle: *OnezHandle, writer_ctx: ?*anyopaque, writer: WriterFn) void {
    handle.output_writer_ctx = writer_ctx;
    handle.output_writer = writer;
    handle.output_stream.impl = handle;
    handle.output_stream.closed = false;
}

fn valuesAreSameParameter(value: Value, parameter: *Parameter) bool {
    return switch (value) {
        .parameter => |p| p == parameter or std.mem.eql(u8, p.name, parameter.name),
        else => false,
    };
}

fn callFreestandingNative(handle: *OnezHandle, name: []const u8) i32 {
    if (std.mem.eql(u8, name, "stdout")) {
        return pushValue(handle, .{ .stream = &handle.output_stream });
    }
    if (std.mem.eql(u8, name, "stream-write")) {
        const bytes = popWritableBytes(handle) orelse return 2;
        const stream = popStream(handle) orelse return 2;
        if (stream.closed) {
            setLastError(handle, "stream is closed", .{});
            return 2;
        }
        const written = stream.vtable.write(stream, bytes) catch |err| {
            setLastError(handle, "stream-write failed: {s}", .{@errorName(err)});
            return 2;
        };
        return pushValue(handle, .{ .fixnum = @intCast(written) });
    }
    if (std.mem.eql(u8, name, "stream-flush")) {
        const stream = popStream(handle) orelse return 2;
        if (stream.closed) {
            setLastError(handle, "stream is closed", .{});
            return 2;
        }
        stream.vtable.flush(stream) catch |err| {
            setLastError(handle, "stream-flush failed: {s}", .{@errorName(err)});
            return 2;
        };
        return 0;
    }
    return unsupportedName(handle, name);
}

export fn onez_init_no_prelude() ?*anyopaque {
    if (freestanding_handle) |*existing| return existing;

    const alloc = allocator();
    const stack = alloc.alignedAlloc(Value, .fromByteUnits(16), freestanding_stack_slots) catch return null;
    freestanding_handle = .{
        .allocator = alloc,
        .stack = stack,
    };
    freestanding_handle.?.output_stream.impl = &freestanding_handle.?;
    return &freestanding_handle.?;
}

export fn onez_init() ?*anyopaque {
    return onez_init_no_prelude();
}

export fn onez_deinit(ptr: ?*anyopaque) void {
    const handle = castHandle(ptr) orelse return;
    clearLastError(handle);
}

export fn onez_freestanding_init_output(ptr: ?*anyopaque, writer_ctx: ?*anyopaque, writer: ?WriterFn) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const write_fn = writer orelse {
        setLastError(handle, "output writer is required", .{});
        return ONEZ_ERR_INVALID_ARGUMENT;
    };
    bindOutputWriter(handle, writer_ctx, write_fn);
    return ONEZ_OK;
}

export fn onez_freestanding_output_stream(ptr: ?*anyopaque) ?*anyopaque {
    const handle = castHandle(ptr) orelse return null;
    return &handle.output_stream;
}

export fn onez_freestanding_output_parameter(ptr: ?*anyopaque) ?*anyopaque {
    const handle = castHandle(ptr) orelse return null;
    return &handle.output_parameter;
}

export fn onez_freestanding_write_output(ptr: ?*anyopaque, bytes_ptr: ?[*]const u8, bytes_len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const p = bytes_ptr orelse return ONEZ_ERR_INVALID_ARGUMENT;
    const written = handle.output_stream.vtable.write(&handle.output_stream, p[0..bytes_len]) catch |err| {
        setLastError(handle, "output write failed: {s}", .{@errorName(err)});
        return ONEZ_ERR_LOAD_FAILED;
    };
    if (written != bytes_len) {
        setLastError(handle, "short output write: wrote {d} of {d} bytes", .{ written, bytes_len });
        return ONEZ_ERR_LOAD_FAILED;
    }
    return ONEZ_OK;
}

export fn onez_set_error(ptr: ?*anyopaque, msg: ?[*]const u8, len: usize) void {
    const handle = castHandle(ptr) orelse return;
    const p = msg orelse return;
    setLastError(handle, "{s}", .{p[0..len]});
}

export fn onez_last_error(ptr: ?*anyopaque) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.last_error) |err| return err.ptr else return null;
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
    protocoldescriptor_slots_ptr: ?*anyopaque,
    constraintcombinator_slots_ptr: ?*anyopaque,
) c_int {
    _ = typevalue_slots_ptr;
    _ = struct_type_slots_ptr;
    _ = marker_slots_ptr;
    _ = tagged_slots_ptr;
    _ = mutable_map_slots_ptr;
    _ = protocoldescriptor_slots_ptr;
    _ = constraintcombinator_slots_ptr;
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    if (parameter_slots_ptr) |slots_raw| {
        const header: *const ImageHeader = @ptrCast(@alignCast(header_ptr orelse return ONEZ_ERR_LOAD_FAILED));
        const table: [*]?*Parameter = @ptrCast(@alignCast(slots_raw));
        var parameter_slots = handle.allocator.alloc(?*Parameter, header.parameter_slot_count) catch return ONEZ_ERR_LOAD_FAILED;
        for (0..header.parameter_slot_count) |i| parameter_slots[i] = table[i];
        if (header.parameter_descriptions) |descs| {
            var i: u32 = 0;
            while (i < header.parameter_slot_count) : (i += 1) {
                const row = descs[i];
                if (row.slot >= header.parameter_slot_count) return ONEZ_ERR_LOAD_FAILED;
                const param = handle.allocator.create(Parameter) catch return ONEZ_ERR_LOAD_FAILED;
                param.* = .{
                    .name = row.name[0..row.name_len],
                    .default_quotation = .{ .instructions = &.{} },
                };
                if (std.mem.eql(u8, param.name, output_parameter_name)) {
                    handle.output_parameter = param.*;
                    parameter_slots[row.slot] = &handle.output_parameter;
                    table[row.slot] = &handle.output_parameter;
                    handle.allocator.destroy(param);
                } else {
                    parameter_slots[row.slot] = param;
                    table[row.slot] = param;
                }
            }
        }
        handle.parameter_slots = parameter_slots;
    }
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
        .items_ptr = handle.stack.ptr,
        .sp_ptr = &handle.stack_len,
        .capacity = handle.stack.len,
        .ctx = handle,
    };
    var status = code_ptr(&jit_ctx);

    while (status == 3) {
        const target = jit_ctx.trampoline_target;
        if (target >= handle.dispatch_table.len) return unsupported(handle, "tail-call target");
        code_ptr = handle.dispatch_table[target] orelse return unsupported(handle, "tail-call target");
        jit_ctx.items_ptr = handle.stack.ptr;
        jit_ctx.capacity = handle.stack.len;
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
    const func: *const fn (*JitContext) callconv(.c) i32 = @ptrFromInt(code_ptr_raw);
    const jit_ctx = contextFromJit(jit_ctx_raw) orelse return 1;
    return func(jit_ctx);
}

export fn jitRefreshStack(jit_ctx_raw: usize) callconv(.c) i32 {
    const jc = contextFromJit(jit_ctx_raw) orelse return 0;
    const handle: *OnezHandle = @ptrCast(@alignCast(jc.ctx));
    jc.items_ptr = handle.stack.ptr;
    jc.capacity = handle.stack.len;
    return 0;
}

export fn jitEnsureStackCapacity(jit_ctx_raw: usize, needed: usize) callconv(.c) i32 {
    const jc = contextFromJit(jit_ctx_raw) orelse return 2;
    if (needed <= jc.capacity) return 0;
    const handle: *OnezHandle = @ptrCast(@alignCast(jc.ctx));
    setLastError(handle, "value stack capacity exceeded", .{});
    return 2;
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
    const handle = handleFromContext(ctx_raw) orelse return 1;
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = handle.allocator.dupe(u8, src[0..str_len]) catch {
        setLastError(handle, "out of memory while materializing string literal", .{});
        return 2;
    };
    return pushValue(handle, .{ .string = copy });
}

export fn jitPushSymbol(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    const handle = handleFromContext(ctx_raw) orelse return 1;
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = handle.allocator.dupe(u8, src[0..str_len]) catch {
        setLastError(handle, "out of memory while materializing symbol literal", .{});
        return 2;
    };
    return pushValue(handle, .{ .symbol = copy });
}

export fn jitPushQuotation(ctx_raw: usize, data_ptr: usize, data_len: usize, dest_raw: usize, quotation_id: usize) callconv(.c) i32 {
    _ = data_ptr;
    _ = data_len;
    _ = dest_raw;
    _ = quotation_id;
    return unsupportedJit(ctx_raw, "quotation literals");
}

export fn jitPushArray(ctx_raw: usize, data_ptr: usize, data_len: usize) callconv(.c) i32 {
    _ = data_ptr;
    _ = data_len;
    return unsupportedJit(ctx_raw, "array literals");
}

export fn jitPushTypeValueSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image typevalue slots");
}

export fn jitPushStructTypeSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image struct-type slots");
}

export fn jitPushMarkerSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image marker slots");
}

export fn jitPushParameterSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    const handle = handleFromContext(ctx_raw) orelse return 1;
    if (slot >= handle.parameter_slots.len) {
        setLastError(handle, "runtime-image parameter slot {d} is not available on this build", .{slot});
        return 2;
    }
    const param = handle.parameter_slots[slot] orelse {
        setLastError(handle, "runtime-image parameter slot {d} is not initialized", .{slot});
        return 2;
    };
    return pushValue(handle, .{ .parameter = param });
}

export fn jitPushTaggedSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image tagged slots");
}

export fn jitPushMutableMapSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image mutable-map slots");
}

export fn jitCallQuotation(ctx_raw: usize) callconv(.c) i32 {
    return unsupportedJit(ctx_raw, "quotation calls");
}

export fn jitGet(ctx_raw: usize) callconv(.c) i32 {
    const handle = handleFromContext(ctx_raw) orelse return 1;
    const parameter_value = popValue(handle) orelse return 2;
    if (valuesAreSameParameter(parameter_value, &handle.output_parameter)) {
        return pushValue(handle, .{ .stream = &handle.output_stream });
    }
    setLastError(handle, "parameter binding is not available on this build", .{});
    return 2;
}

export fn jitWithParameter(ctx_raw: usize) callconv(.c) i32 {
    return unsupportedJit(ctx_raw, "dynamic parameter scopes");
}

export fn jitInterpretedCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    _ = word_id_raw;
    _ = line_raw;
    return unsupportedJit(ctx_raw, "interpreter fallback");
}

export fn jitNativeWordCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    _ = line_raw;
    const handle = handleFromContext(ctx_raw) orelse return 1;
    if (word_id_raw >= handle.word_names.len) return unsupportedJit(ctx_raw, "native helper calls");
    const name_ptr = handle.word_names[word_id_raw] orelse return unsupportedJit(ctx_raw, "native helper calls");
    return callFreestandingNative(handle, std.mem.span(name_ptr));
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

test "freestanding literal helpers push string and symbol values" {
    var stack: [4]Value align(16) = undefined;
    var handle = OnezHandle{
        .allocator = std.testing.allocator,
        .stack = stack[0..],
    };
    defer clearLastError(&handle);
    defer {
        for (handle.stack[0..handle.stack_len]) |value| switch (value) {
            .string => |s| std.testing.allocator.free(s),
            .symbol => |s| std.testing.allocator.free(s),
            else => {},
        };
    }

    const text = "hello";
    try std.testing.expectEqual(@as(i32, 0), jitPushString(@intFromPtr(&handle), @intFromPtr(text.ptr), text.len));
    try std.testing.expectEqual(@as(usize, 1), handle.stack_len);
    try std.testing.expectEqualStrings(text, handle.stack[0].string);

    const sym = "name";
    try std.testing.expectEqual(@as(i32, 0), jitPushSymbol(@intFromPtr(&handle), @intFromPtr(sym.ptr), sym.len));
    try std.testing.expectEqual(@as(usize, 2), handle.stack_len);
    try std.testing.expectEqualStrings(sym, handle.stack[1].symbol);
}

test "freestanding unsupported native helper records clear last_error" {
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{
        .allocator = std.testing.allocator,
        .stack = stack[0..],
    };
    defer clearLastError(&handle);

    try std.testing.expectEqual(@as(i32, 2), jitNativeWordCall(@intFromPtr(&handle), 7, 1));
    const msg = onez_last_error(&handle) orelse return error.TestExpectedError;
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), "native helper calls is not available on this build") != null);
}

test "freestanding stack capacity helper refreshes or reports overflow" {
    var stack: [2]Value align(16) = undefined;
    var handle = OnezHandle{
        .allocator = std.testing.allocator,
        .stack = stack[0..],
    };
    defer clearLastError(&handle);

    var sp: usize = 0;
    var jit_ctx = JitContext{
        .items_ptr = stack[0..].ptr,
        .sp_ptr = &sp,
        .capacity = 1,
        .ctx = &handle,
    };

    try std.testing.expectEqual(@as(i32, 0), jitRefreshStack(@intFromPtr(&jit_ctx)));
    try std.testing.expectEqual(stack[0..].ptr, jit_ctx.items_ptr);
    try std.testing.expectEqual(@as(usize, 2), jit_ctx.capacity);
    try std.testing.expectEqual(@as(i32, 2), jitEnsureStackCapacity(@intFromPtr(&jit_ctx), 3));
    const msg = onez_last_error(&handle) orelse return error.TestExpectedError;
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), "value stack capacity exceeded") != null);
}

const FakeWriter = struct {
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    fn write(ctx: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) usize {
        const self: *FakeWriter = @ptrCast(@alignCast(ctx.?));
        self.buffer.appendSlice(self.allocator, ptr[0..len]) catch return 0;
        return len;
    }
};

test "freestanding output init accepts fake UART writer and direct writes" {
    var stack: [2]Value align(16) = undefined;
    var handle = OnezHandle{
        .allocator = std.testing.allocator,
        .stack = stack[0..],
    };
    handle.output_stream.impl = &handle;
    defer clearLastError(&handle);

    var written = std.ArrayListUnmanaged(u8){};
    defer written.deinit(std.testing.allocator);
    var fake = FakeWriter{
        .buffer = &written,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqual(ONEZ_OK, onez_freestanding_init_output(&handle, &fake, FakeWriter.write));
    try std.testing.expectEqual(ONEZ_OK, onez_freestanding_write_output(&handle, "uart".ptr, 4));
    try std.testing.expectEqualStrings("uart", written.items);
}

test "freestanding output parameter binding writes through stream native" {
    var stack: [8]Value align(16) = undefined;
    var word_names: [2]?[*:0]const u8 = .{ "stream-write", "stream-flush" };
    var handle = OnezHandle{
        .allocator = std.testing.allocator,
        .stack = stack[0..],
        .word_names = word_names[0..],
    };
    handle.output_stream.impl = &handle;
    defer clearLastError(&handle);

    var written = std.ArrayListUnmanaged(u8){};
    defer written.deinit(std.testing.allocator);
    var fake = FakeWriter{
        .buffer = &written,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqual(ONEZ_OK, onez_freestanding_init_output(&handle, &fake, FakeWriter.write));
    try std.testing.expectEqual(@as(i32, 0), pushValue(&handle, .{ .parameter = &handle.output_parameter }));
    try std.testing.expectEqual(@as(i32, 0), jitGet(@intFromPtr(&handle)));
    try std.testing.expectEqual(@as(i32, 0), pushValue(&handle, .{ .string = "hello" }));
    try std.testing.expectEqual(@as(i32, 0), jitNativeWordCall(@intFromPtr(&handle), 0, 1));
    try std.testing.expectEqual(@as(usize, 1), handle.stack_len);
    try std.testing.expectEqual(@as(i64, 5), handle.stack[0].fixnum);
    try std.testing.expectEqualStrings("hello", written.items);
}
