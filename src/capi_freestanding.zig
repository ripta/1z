const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const populate_core = @import("aot_image_populate_core.zig");
const value_mod = @import("value.zig");
const dispatch_mod = @import("dispatch.zig");

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

const Segment = struct {
    captures: []const Value,
    base_code_ptr: *const anyopaque,
};

const Closure = struct {
    instructions: []const Instruction,
    effect: ?*const StackEffect = null,
    segments: []const Segment,
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
    closure: *Closure,
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

// Export the C symbol surface only on freestanding targets. Host test builds
// of this file transitively analyze `ir_codegen.zig`, which exports the same
// `jit*` names, so unconditional `export fn` collides there.
comptime {
    if (builtin.os.tag == .freestanding) {
        @export(&onez_init_no_prelude, .{ .name = "onez_init_no_prelude" });
        @export(&onez_init, .{ .name = "onez_init" });
        @export(&onez_deinit, .{ .name = "onez_deinit" });
        @export(&onez_freestanding_init_output, .{ .name = "onez_freestanding_init_output" });
        @export(&onez_freestanding_output_stream, .{ .name = "onez_freestanding_output_stream" });
        @export(&onez_freestanding_output_parameter, .{ .name = "onez_freestanding_output_parameter" });
        @export(&onez_freestanding_write_output, .{ .name = "onez_freestanding_write_output" });
        @export(&onez_set_error, .{ .name = "onez_set_error" });
        @export(&onez_last_error, .{ .name = "onez_last_error" });
        @export(&onez_load_runtime_image, .{ .name = "onez_load_runtime_image" });
        @export(&onez_runtime_register_compiled, .{ .name = "onez_runtime_register_compiled" });
        @export(&onez_runtime_register_quotations, .{ .name = "onez_runtime_register_quotations" });
        @export(&onez_replay_method_dispatch, .{ .name = "onez_replay_method_dispatch" });
        @export(&onez_runtime_run, .{ .name = "onez_runtime_run" });
        @export(&onez_set_interpreter_fallback, .{ .name = "onez_set_interpreter_fallback" });
        @export(&onez_print_error, .{ .name = "onez_print_error" });
        @export(&onez_set_args, .{ .name = "onez_set_args" });
        @export(&onez_set_static_libs, .{ .name = "onez_set_static_libs" });
        @export(&jitCallCodePtr, .{ .name = "jitCallCodePtr" });
        @export(&jitCallValue, .{ .name = "jitCallValue" });
        @export(&jitRefreshStack, .{ .name = "jitRefreshStack" });
        @export(&jitEnsureStackCapacity, .{ .name = "jitEnsureStackCapacity" });
        @export(&jitRetainSlot, .{ .name = "jitRetainSlot" });
        @export(&jitReleaseSlot, .{ .name = "jitReleaseSlot" });
        @export(&jitPushString, .{ .name = "jitPushString" });
        @export(&jitPushSymbol, .{ .name = "jitPushSymbol" });
        @export(&jitPushQuotation, .{ .name = "jitPushQuotation" });
        @export(&jitPushArray, .{ .name = "jitPushArray" });
        @export(&jitPushTypeValueSlot, .{ .name = "jitPushTypeValueSlot" });
        @export(&jitPushStructTypeSlot, .{ .name = "jitPushStructTypeSlot" });
        @export(&jitPushMarkerSlot, .{ .name = "jitPushMarkerSlot" });
        @export(&jitPushParameterSlot, .{ .name = "jitPushParameterSlot" });
        @export(&jitPushTaggedSlot, .{ .name = "jitPushTaggedSlot" });
        @export(&jitPushMutableMapSlot, .{ .name = "jitPushMutableMapSlot" });
        @export(&jitCallQuotation, .{ .name = "jitCallQuotation" });
        @export(&jitGet, .{ .name = "jitGet" });
        @export(&jitWithParameter, .{ .name = "jitWithParameter" });
        @export(&jitInterpretedCall, .{ .name = "jitInterpretedCall" });
        @export(&jitNativeWordCall, .{ .name = "jitNativeWordCall" });
        @export(&jitOverflowError, .{ .name = "jitOverflowError" });
        @export(&jitDivisionByZeroError, .{ .name = "jitDivisionByZeroError" });
        @export(&jitStackUnderflowError, .{ .name = "jitStackUnderflowError" });
        @export(&jitTypeMismatchError, .{ .name = "jitTypeMismatchError" });
        @export(&jitNullCodePtrError, .{ .name = "jitNullCodePtrError" });
    }
}

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

    // Slot tables retained from the runtime image, mirroring the hosted
    // Context's `image_*` caching. Struct types are reachable through the
    // typevalue descriptors, so no struct-type table is retained.
    image_typevalue_slots: ?populate_core.SlotTable = null,
    image_typevalue_slot_count: u32 = 0,
    image_protocoldescriptor_slots: ?populate_core.ProtocolDescriptorSlotTable = null,
    image_protocoldescriptor_slot_count: u32 = 0,
    image_constraintcombinator_slots: ?populate_core.ConstraintCombinatorSlotTable = null,
    image_constraintcombinator_slot_count: u32 = 0,
    image_dispatch_entry_descriptions: ?[*]const populate_core.DispatchEntryDescription = null,
    image_dispatch_entry_count: u32 = 0,

    // Method-dispatch registry the replay populates, plus the synthetic
    // unary/any key sentinels, mirroring the hosted Context's `dispatch` and
    // `dispatch_*_sentinel` fields. Named `method_dispatch` because
    // `dispatch_table` above is the word-id-to-function table.
    method_dispatch: ?dispatch_mod.DispatchTable = null,
    dispatch_any_sentinel: ?*value_mod.TypeValue = null,
    dispatch_unary_sentinel: ?*value_mod.TypeValue = null,
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

fn onez_init_no_prelude() callconv(.c) ?*anyopaque {
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

fn onez_init() callconv(.c) ?*anyopaque {
    return onez_init_no_prelude();
}

fn onez_deinit(ptr: ?*anyopaque) callconv(.c) void {
    const handle = castHandle(ptr) orelse return;
    clearLastError(handle);
}

fn onez_freestanding_init_output(ptr: ?*anyopaque, writer_ctx: ?*anyopaque, writer: ?WriterFn) callconv(.c) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const write_fn = writer orelse {
        setLastError(handle, "output writer is required", .{});
        return ONEZ_ERR_INVALID_ARGUMENT;
    };
    bindOutputWriter(handle, writer_ctx, write_fn);
    return ONEZ_OK;
}

fn onez_freestanding_output_stream(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const handle = castHandle(ptr) orelse return null;
    return &handle.output_stream;
}

fn onez_freestanding_output_parameter(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const handle = castHandle(ptr) orelse return null;
    return &handle.output_parameter;
}

fn onez_freestanding_write_output(ptr: ?*anyopaque, bytes_ptr: ?[*]const u8, bytes_len: usize) callconv(.c) c_int {
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

fn onez_set_error(ptr: ?*anyopaque, msg: ?[*]const u8, len: usize) callconv(.c) void {
    const handle = castHandle(ptr) orelse return;
    const p = msg orelse return;
    setLastError(handle, "{s}", .{p[0..len]});
}

fn onez_last_error(ptr: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.last_error) |err| return err.ptr else return null;
}

/// Freestanding environment for `SlotPopulateCore`: no prelude and no
/// registry, so the reuse lookups always miss and the create hooks only
/// allocate. Name slices point at the binary's static image data.
const FreestandingPopulateEnv = struct {
    alloc: std.mem.Allocator,

    pub fn allocator(self: FreestandingPopulateEnv) std.mem.Allocator {
        return self.alloc;
    }

    pub fn lookupTypeValueByName(_: FreestandingPopulateEnv, _: []const u8) ?*value_mod.TypeValue {
        return null;
    }

    pub fn lookupEnumVariantTypeValueByName(_: FreestandingPopulateEnv, _: []const u8) ?*value_mod.TypeValue {
        return null;
    }

    pub fn lookupStructTypeByName(_: FreestandingPopulateEnv, _: []const u8) ?*value_mod.StructType {
        return null;
    }

    pub fn lookupProtocolByName(_: FreestandingPopulateEnv, _: []const u8) ?*value_mod.ProtocolDescriptor {
        return null;
    }

    pub fn createProtocolDescriptor(
        self: FreestandingPopulateEnv,
        name: []const u8,
        methods: []const value_mod.Value,
        protocol_id: u32,
    ) populate_core.LoaderError!*value_mod.ProtocolDescriptor {
        const pd = self.alloc.create(value_mod.ProtocolDescriptor) catch
            return populate_core.LoaderError.OutOfMemory;
        // The caller's methods list is transient; copy it.
        const methods_dup = self.alloc.alloc(value_mod.Value, methods.len) catch
            return populate_core.LoaderError.OutOfMemory;
        @memcpy(methods_dup, methods);
        pd.* = .{
            .name = name,
            .methods = methods_dup,
            .protocol_id = protocol_id,
        };
        return pd;
    }

    pub fn createConstraintCombinator(
        self: FreestandingPopulateEnv,
        kind: value_mod.ConstraintCombinator.Kind,
        elements: []const value_mod.ConstraintCombinator.Element,
        combinator_id: u32,
    ) populate_core.LoaderError!*value_mod.ConstraintCombinator {
        const cc = self.alloc.create(value_mod.ConstraintCombinator) catch
            return populate_core.LoaderError.OutOfMemory;
        // The element list is already on this heap; take ownership.
        cc.* = .{
            .kind = kind,
            .elements = elements,
            .combinator_id = combinator_id,
        };
        return cc;
    }
};

const FreestandingPopulate = populate_core.SlotPopulateCore(FreestandingPopulateEnv);

fn reportLoadError(handle: *OnezHandle, err: populate_core.LoaderError) c_int {
    setLastError(handle, "runtime image load failed: {s}", .{@errorName(err)});
    return ONEZ_ERR_LOAD_FAILED;
}

fn onez_load_runtime_image(
    ptr: ?*anyopaque,
    header_ptr: ?*const anyopaque,
    typevalue_slots_ptr: ?*anyopaque,
    struct_type_slots_ptr: ?*anyopaque,
    marker_slots_ptr: ?*anyopaque,
    parameter_slots_ptr: ?*anyopaque,
    tagged_slots_ptr: ?*anyopaque,
    mutable_map_slots_ptr: ?*anyopaque,
    struct_instance_slots_ptr: ?*anyopaque,
    vector_slots_ptr: ?*anyopaque,
    protocoldescriptor_slots_ptr: ?*anyopaque,
    constraintcombinator_slots_ptr: ?*anyopaque,
) callconv(.c) c_int {
    _ = marker_slots_ptr;
    _ = tagged_slots_ptr;
    _ = mutable_map_slots_ptr;
    _ = struct_instance_slots_ptr;
    _ = vector_slots_ptr;
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const header: *const populate_core.Header = @ptrCast(@alignCast(header_ptr orelse return ONEZ_ERR_LOAD_FAILED));

    const typevalue_slots: ?populate_core.SlotTable =
        if (typevalue_slots_ptr) |p| @ptrCast(@alignCast(p)) else null;
    const struct_type_slots: ?populate_core.StructTypeSlotTable =
        if (struct_type_slots_ptr) |p| @ptrCast(@alignCast(p)) else null;
    const protocol_slots: ?populate_core.ProtocolDescriptorSlotTable =
        if (protocoldescriptor_slots_ptr) |p| @ptrCast(@alignCast(p)) else null;
    const combinator_slots: ?populate_core.ConstraintCombinatorSlotTable =
        if (constraintcombinator_slots_ptr) |p| @ptrCast(@alignCast(p)) else null;

    // Hosted order: protocols, then typevalues, then combinators, whose
    // elements read both prior tables.
    const env = FreestandingPopulateEnv{ .alloc = handle.allocator };
    FreestandingPopulate.populateProtocolDescriptorSlots(env, header, protocol_slots) catch |err|
        return reportLoadError(handle, err);
    _ = FreestandingPopulate.populateTypeValueSlots(env, header, typevalue_slots, struct_type_slots) catch |err|
        return reportLoadError(handle, err);
    FreestandingPopulate.populateConstraintCombinatorSlots(env, header, .{
        .typevalues = typevalue_slots,
        .protocol_descriptors = protocol_slots,
        .constraint_combinators = combinator_slots,
    }) catch |err|
        return reportLoadError(handle, err);

    if (typevalue_slots) |table| {
        handle.image_typevalue_slots = table;
        handle.image_typevalue_slot_count = header.typevalue_slot_count;
    }
    if (protocol_slots) |table| {
        handle.image_protocoldescriptor_slots = table;
        handle.image_protocoldescriptor_slot_count = header.protocoldescriptor_slot_count;
    }
    if (combinator_slots) |table| {
        handle.image_constraintcombinator_slots = table;
        handle.image_constraintcombinator_slot_count = header.constraintcombinator_slot_count;
    }

    // Stash the dispatch-entry rows for `onez_replay_method_dispatch`, which
    // runs after the quotation-function table is registered.
    handle.image_dispatch_entry_descriptions = header.dispatch_entry_descriptions;
    handle.image_dispatch_entry_count = header.dispatch_entry_slot_count;

    if (parameter_slots_ptr) |slots_raw| {
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

fn onez_runtime_register_compiled(ptr: ?*anyopaque, table: [*]const ?*const anyopaque, names: [*]const ?[*:0]const u8, size: u32) callconv(.c) i32 {
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

fn onez_runtime_register_quotations(ptr: ?*anyopaque, table: [*]const ?*const anyopaque, size: u32) callconv(.c) i32 {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const n: usize = @intCast(size);

    const quotations = handle.allocator.alloc(?OnezWordFn, n) catch return ONEZ_ERR_LOAD_FAILED;
    for (0..n) |i| {
        quotations[i] = if (table[i]) |code_ptr| @ptrCast(@alignCast(code_ptr)) else null;
    }

    handle.quotation_table = quotations;
    return ONEZ_OK;
}

/// Lazily create the synthetic unary/any dispatch key sentinels, mirroring
/// the hosted Context's `initSentinelTypeValues`.
fn ensureDispatchSentinels(handle: *OnezHandle) !void {
    if (handle.dispatch_any_sentinel == null) {
        const desc = try value_mod.createSentinelTypeDescriptor(handle.allocator);
        const tv = try handle.allocator.create(value_mod.TypeValue);
        tv.* = .{ .name = "*", .descriptor = desc };
        handle.dispatch_any_sentinel = tv;
    }
    if (handle.dispatch_unary_sentinel == null) {
        const desc = try value_mod.createSentinelTypeDescriptor(handle.allocator);
        const tv = try handle.allocator.create(value_mod.TypeValue);
        tv.* = .{ .name = "", .descriptor = desc };
        handle.dispatch_unary_sentinel = tv;
    }
}

/// Mirror of the hosted loader's `resolveDispatchTypeDescriptor`: the
/// reserved sentinels map to the handle's synthetic descriptors, and a real
/// slot resolves through the retained typevalue slot table. Requires
/// `ensureDispatchSentinels` to have run.
fn resolveFreestandingDispatchTypeDescriptor(handle: *OnezHandle, slot: u32) ?*const value_mod.TypeDescriptor {
    if (slot == populate_core.dispatch_type_unary) return handle.dispatch_unary_sentinel.?.descriptor.?;
    if (slot == populate_core.dispatch_type_any) return handle.dispatch_any_sentinel.?.descriptor.?;
    const tv_or_err = populate_core.lookupSlot(
        handle.image_typevalue_slots,
        handle.image_typevalue_slot_count,
        slot,
    ) catch return null;
    const tv = tv_or_err orelse return null;
    return tv.descriptor;
}

/// Replay the image's freeze-time method dispatch entries into the handle's
/// method-dispatch registry, keyed on each row's serialized `dispatch_id`
/// verbatim -- the same id compiled call sites bake.
///
/// Compiled-body arm only: strict freestanding builds refuse non-compilable
/// replayable bodies at build time, so an interpreter-run row here means a
/// malformed image and fails the replay rather than being skipped the way
/// the hosted replay skips it.
fn onez_replay_method_dispatch(ptr: ?*anyopaque) callconv(.c) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const count = handle.image_dispatch_entry_count;
    if (count == 0) return ONEZ_OK;
    const rows = handle.image_dispatch_entry_descriptions orelse return ONEZ_OK;

    ensureDispatchSentinels(handle) catch {
        setLastError(handle, "method dispatch replay failed: out of memory", .{});
        return ONEZ_ERR_LOAD_FAILED;
    };
    if (handle.method_dispatch == null) {
        handle.method_dispatch = dispatch_mod.DispatchTable.init(handle.allocator);
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const row = rows[i];

        const type_a = resolveFreestandingDispatchTypeDescriptor(handle, row.type_a_slot) orelse {
            setLastError(handle, "method dispatch replay failed: dispatch id {d} has unresolvable type slot {d}", .{ row.dispatch_id, row.type_a_slot });
            return ONEZ_ERR_LOAD_FAILED;
        };
        const type_b = resolveFreestandingDispatchTypeDescriptor(handle, row.type_b_slot) orelse {
            setLastError(handle, "method dispatch replay failed: dispatch id {d} has unresolvable type slot {d}", .{ row.dispatch_id, row.type_b_slot });
            return ONEZ_ERR_LOAD_FAILED;
        };

        if (row.quotation_id == populate_core.dispatch_interp_quotation_id_sentinel) {
            setLastError(handle, "method dispatch replay failed: dispatch id {d} carries an interpreter-run body", .{row.dispatch_id});
            return ONEZ_ERR_LOAD_FAILED;
        }
        if (row.quotation_id >= handle.quotation_table.len) {
            setLastError(handle, "method dispatch replay failed: dispatch id {d} references missing compiled body {d}", .{ row.dispatch_id, row.quotation_id });
            return ONEZ_ERR_LOAD_FAILED;
        }
        const body_fn = handle.quotation_table[row.quotation_id] orelse {
            setLastError(handle, "method dispatch replay failed: dispatch id {d} references missing compiled body {d}", .{ row.dispatch_id, row.quotation_id });
            return ONEZ_ERR_LOAD_FAILED;
        };

        const key = dispatch_mod.DispatchKey{
            .dispatch_id = row.dispatch_id,
            .type_a = type_a,
            .type_b = type_b,
        };
        const entry = dispatch_mod.DispatchEntry{
            .body = .{ .quotation = .{ .instructions = &.{}, .code_ptr = @ptrCast(body_fn) } },
        };
        handle.method_dispatch.?.register(key, entry, false) catch |err| switch (err) {
            // A duplicate key can only come from the image registering the same
            // method twice; the bodies are identical, so keeping the first is safe.
            error.DuplicateMethod => {},
            else => {
                setLastError(handle, "method dispatch replay failed: out of memory", .{});
                return ONEZ_ERR_LOAD_FAILED;
            },
        };
    }
    return ONEZ_OK;
}

fn onez_runtime_run(ptr: ?*anyopaque, entry_word_id: u32) callconv(.c) i32 {
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

fn onez_set_interpreter_fallback(ptr: ?*anyopaque, allowed: bool) callconv(.c) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.interpreter_fallback_allowed = allowed;
    return ONEZ_OK;
}

fn onez_print_error(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
}

fn onez_set_args(ptr: ?*anyopaque, argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int {
    _ = ptr;
    _ = argc;
    _ = argv;
    return ONEZ_OK;
}

fn onez_set_static_libs(ptr: ?*anyopaque, names: [*]const [*:0]const u8, count: u32) callconv(.c) c_int {
    _ = ptr;
    _ = names;
    _ = count;
    return ONEZ_ERR_LOAD_FAILED;
}

fn jitCallCodePtr(jit_ctx_raw: usize, code_ptr_raw: usize) callconv(.c) i32 {
    if (code_ptr_raw == 0) return 1;
    const func: *const fn (*JitContext) callconv(.c) i32 = @ptrFromInt(code_ptr_raw);
    const jit_ctx = contextFromJit(jit_ctx_raw) orelse return 1;
    return func(jit_ctx);
}

/// Unified interpreter-free dispatch for a runtime-selected `call`: run the
/// callable at the slot's Value pointer. A quotation calls its code_ptr (or
/// traps cleanly if it was never compiled); a closure pushes each segment's
/// captured prefix and calls that segment's base. The fixed freestanding stack
/// never reallocates, so no retain or buffer refresh is needed.
fn jitCallValue(jit_ctx_raw: usize, value_ptr_raw: usize) callconv(.c) i32 {
    if (value_ptr_raw == 0) return 1;
    const jit_ctx = contextFromJit(jit_ctx_raw) orelse return 1;
    const handle: *OnezHandle = @ptrCast(@alignCast(jit_ctx.ctx));
    const v: *const Value = @ptrFromInt(value_ptr_raw);
    switch (v.*) {
        .quotation => |q| {
            const ptr = q.code_ptr orelse return unsupported(handle, "uncompiled quotation call");
            const func: *const fn (*JitContext) callconv(.c) i32 = @ptrFromInt(@intFromPtr(ptr));
            return func(jit_ctx);
        },
        .closure => |cl| {
            // A scope-carrying closure over an uncompiled base has no segments; its body is meant
            // for the interpreter, which an interpreter-free binary lacks, so trap cleanly like an
            // uncompiled quotation rather than silently running zero segments.
            if (cl.segments.len == 0) return unsupported(handle, "uncompiled closure call");
            for (cl.segments) |seg| {
                for (seg.captures) |cap| {
                    const status = pushValue(handle, cap);
                    if (status != 0) return status;
                }
                jit_ctx.items_ptr = handle.stack.ptr;
                jit_ctx.capacity = handle.stack.len;
                const func: *const fn (*JitContext) callconv(.c) i32 = @ptrFromInt(@intFromPtr(seg.base_code_ptr));
                const status = func(jit_ctx);
                if (status != 0) return status;
            }
            return 0;
        },
        else => return unsupported(handle, "call of non-quotation value"),
    }
}

fn jitRefreshStack(jit_ctx_raw: usize) callconv(.c) i32 {
    const jc = contextFromJit(jit_ctx_raw) orelse return 0;
    const handle: *OnezHandle = @ptrCast(@alignCast(jc.ctx));
    jc.items_ptr = handle.stack.ptr;
    jc.capacity = handle.stack.len;
    return 0;
}

fn jitEnsureStackCapacity(jit_ctx_raw: usize, needed: usize) callconv(.c) i32 {
    const jc = contextFromJit(jit_ctx_raw) orelse return 2;
    if (needed <= jc.capacity) return 0;
    const handle: *OnezHandle = @ptrCast(@alignCast(jc.ctx));
    setLastError(handle, "value stack capacity exceeded", .{});
    return 2;
}

fn jitRetainSlot(value_ptr: usize) callconv(.c) i32 {
    _ = value_ptr;
    return 0;
}

fn jitReleaseSlot(value_ptr: usize) callconv(.c) i32 {
    _ = value_ptr;
    return 0;
}

fn jitPushString(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    const handle = handleFromContext(ctx_raw) orelse return 1;
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = handle.allocator.dupe(u8, src[0..str_len]) catch {
        setLastError(handle, "out of memory while materializing string literal", .{});
        return 2;
    };
    return pushValue(handle, .{ .string = copy });
}

fn jitPushSymbol(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    const handle = handleFromContext(ctx_raw) orelse return 1;
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = handle.allocator.dupe(u8, src[0..str_len]) catch {
        setLastError(handle, "out of memory while materializing symbol literal", .{});
        return 2;
    };
    return pushValue(handle, .{ .symbol = copy });
}

fn jitPushQuotation(ctx_raw: usize, data_ptr: usize, data_len: usize, dest_raw: usize, quotation_id: usize) callconv(.c) i32 {
    _ = data_ptr;
    _ = data_len;
    _ = dest_raw;
    _ = quotation_id;
    return unsupportedJit(ctx_raw, "quotation literals");
}

fn jitPushArray(ctx_raw: usize, data_ptr: usize, data_len: usize) callconv(.c) i32 {
    _ = data_ptr;
    _ = data_len;
    return unsupportedJit(ctx_raw, "array literals");
}

fn jitPushTypeValueSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image typevalue slots");
}

fn jitPushStructTypeSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image struct-type slots");
}

fn jitPushMarkerSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image marker slots");
}

fn jitPushParameterSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
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

fn jitPushTaggedSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image tagged slots");
}

fn jitPushMutableMapSlot(ctx_raw: usize, slot: usize) callconv(.c) i32 {
    _ = slot;
    return unsupportedJit(ctx_raw, "runtime-image mutable-map slots");
}

fn jitCallQuotation(ctx_raw: usize) callconv(.c) i32 {
    return unsupportedJit(ctx_raw, "quotation calls");
}

fn jitGet(ctx_raw: usize) callconv(.c) i32 {
    const handle = handleFromContext(ctx_raw) orelse return 1;
    const parameter_value = popValue(handle) orelse return 2;
    if (valuesAreSameParameter(parameter_value, &handle.output_parameter)) {
        return pushValue(handle, .{ .stream = &handle.output_stream });
    }
    setLastError(handle, "parameter binding is not available on this build", .{});
    return 2;
}

fn jitWithParameter(ctx_raw: usize) callconv(.c) i32 {
    return unsupportedJit(ctx_raw, "dynamic parameter scopes");
}

fn jitInterpretedCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    _ = word_id_raw;
    _ = line_raw;
    return unsupportedJit(ctx_raw, "interpreter fallback");
}

fn jitNativeWordCall(ctx_raw: usize, word_id_raw: usize, line_raw: usize) callconv(.c) i32 {
    _ = line_raw;
    const handle = handleFromContext(ctx_raw) orelse return 1;
    if (word_id_raw >= handle.word_names.len) return unsupportedJit(ctx_raw, "native helper calls");
    const name_ptr = handle.word_names[word_id_raw] orelse return unsupportedJit(ctx_raw, "native helper calls");
    return callFreestandingNative(handle, std.mem.span(name_ptr));
}

fn jitOverflowError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}

fn jitDivisionByZeroError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}

fn jitStackUnderflowError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}

fn jitTypeMismatchError(ctx_raw: usize) callconv(.c) i32 {
    _ = ctx_raw;
    return 2;
}

fn jitNullCodePtrError(ctx_raw: usize) callconv(.c) i32 {
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

fn emptyTestImageHeader() populate_core.Header {
    return .{
        .format_version = 1,
        .module_count = 0,
        .word_count = 0,
        .marker_pool_count = 0,
        .typevalue_slot_count = 1,
        .stack_effect_count = 0,
        .typevalue_count = 0,
        .struct_type_count = 0,
        .marker_slot_count = 0,
        .parameter_slot_count = 0,
        .tagged_slot_count = 0,
        .mutable_map_slot_count = 0,
        .struct_instance_slot_count = 0,
        .vector_slot_count = 0,
        .protocoldescriptor_slot_count = 0,
        .constraintcombinator_slot_count = 0,
        .dispatch_entry_slot_count = 0,
        .modules = null,
        .words = null,
        .markers = null,
        .stack_effects = null,
        .typevalues = null,
        .typedescriptors = null,
        .struct_types = null,
        .marker_descriptions = null,
        .parameter_descriptions = null,
        .tagged_descriptions = null,
        .mutable_map_descriptions = null,
        .struct_instance_descriptions = null,
        .vector_descriptions = null,
        .protocoldescriptor_descriptions = null,
        .constraintcombinator_descriptions = null,
        .dispatch_entry_descriptions = null,
    };
}

test "freestanding loader retains typevalue slots from a synthetic image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };

    const descs = [_]populate_core.TypeDescriptor{
        std.mem.zeroes(populate_core.TypeDescriptor),
        std.mem.zeroes(populate_core.TypeDescriptor),
    };
    const rows = [_]populate_core.TypeValueRow{
        .{ .name = "alpha", .name_len = 5, .slot = 1, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
        .{ .name = "beta", .name_len = 4, .slot = 2, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
    };
    var header = emptyTestImageHeader();
    header.typevalue_slot_count = 3;
    header.typevalue_count = rows.len;
    header.typevalues = &rows;
    header.typedescriptors = &descs;

    var tv_slots = [_]?*const value_mod.TypeValue{ null, null, null };
    try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
        &handle,
        &header,
        @ptrCast(&tv_slots),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    ));

    try std.testing.expectEqual(@as(u32, 3), handle.image_typevalue_slot_count);
    try std.testing.expectEqual(@as(?populate_core.SlotTable, @ptrCast(&tv_slots)), handle.image_typevalue_slots);
    try std.testing.expectEqualStrings("alpha", tv_slots[1].?.name);
    try std.testing.expectEqualStrings("beta", tv_slots[2].?.name);
    try std.testing.expect(tv_slots[1].?.descriptor != null);
}

test "freestanding loader resolves the typevalue-to-struct-type interlink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };

    const point_field_names = [_][*]const u8{ "x", "y" };
    const point_field_lens = [_]u32{ 1, 1 };
    const struct_rows = [_]populate_core.StructType{
        .{
            .name = "point",
            .name_len = 5,
            .field_names = &point_field_names,
            .field_name_lens = &point_field_lens,
            .field_count = 2,
            .field_type_slots = null,
            .field_type_count = 0,
        },
    };
    var virtual_desc = std.mem.zeroes(populate_core.TypeDescriptor);
    virtual_desc.kind = 3;
    virtual_desc.anon_struct_idx = 0;
    virtual_desc.parent_type_slot = 0;
    const descs = [_]populate_core.TypeDescriptor{virtual_desc};
    const rows = [_]populate_core.TypeValueRow{
        .{ .name = "point", .name_len = 5, .slot = 1, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
    };
    var header = emptyTestImageHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = rows.len;
    header.typevalues = &rows;
    header.typedescriptors = &descs;
    header.struct_type_count = struct_rows.len;
    header.struct_types = &struct_rows;

    var tv_slots = [_]?*const value_mod.TypeValue{ null, null };
    var st_slots = [_]?*value_mod.StructType{null};
    try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
        &handle,
        &header,
        @ptrCast(&tv_slots),
        @ptrCast(&st_slots),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    ));

    const tv = tv_slots[1].?;
    const st = st_slots[0].?;
    try std.testing.expectEqualStrings("point", st.name);
    try std.testing.expectEqual(@as(usize, 2), st.fields.len);
    try std.testing.expectEqual(@as(?*const value_mod.StructType, st), tv.descriptor.?.kind.virtual.anon_struct);
    try std.testing.expectEqual(@as(?*value_mod.TypeValue, @constCast(tv)), st.type_val);
    try std.testing.expectEqual(@as(?*value_mod.TypeValue, @constCast(tv)), tv.virtual_type.?.type_val);
}

test "freestanding loader retains protocol descriptor slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };

    const methods = [_]populate_core.ProtocolMethod{
        .{ .name = "area", .name_len = 4, .stack_effect_idx = 0 },
    };
    const rows = [_]populate_core.ProtocolDescriptorDescription{
        .{ .name = "shape", .name_len = 5, .slot = 0, .protocol_id = 7, .method_count = 1, .methods = &methods },
    };
    var header = emptyTestImageHeader();
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &rows;

    var pd_slots = [_]?*const value_mod.ProtocolDescriptor{null};
    try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
        &handle,
        &header,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        @ptrCast(&pd_slots),
        null,
    ));

    try std.testing.expectEqual(@as(u32, 1), handle.image_protocoldescriptor_slot_count);
    try std.testing.expectEqual(@as(?populate_core.ProtocolDescriptorSlotTable, @ptrCast(&pd_slots)), handle.image_protocoldescriptor_slots);
    const pd = pd_slots[0].?;
    try std.testing.expectEqualStrings("shape", pd.name);
    try std.testing.expectEqual(@as(u32, 7), pd.protocol_id);
    try std.testing.expectEqual(@as(usize, 1), pd.methods.len);
    try std.testing.expectEqualStrings("area", pd.methods[0].symbol);
}

test "freestanding loader retains constraint combinator slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };

    const descs = [_]populate_core.TypeDescriptor{std.mem.zeroes(populate_core.TypeDescriptor)};
    const tv_rows = [_]populate_core.TypeValueRow{
        .{ .name = "alpha", .name_len = 5, .slot = 1, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
    };
    const pd_rows = [_]populate_core.ProtocolDescriptorDescription{
        .{ .name = "shape", .name_len = 5, .slot = 0, .protocol_id = 1, .method_count = 0, .methods = null },
    };
    const first_elements = [_]populate_core.CombinatorElement{
        .{ .kind = 1, .slot = 1 },
        .{ .kind = 2, .slot = 0 },
    };
    const nested_elements = [_]populate_core.CombinatorElement{
        .{ .kind = 3, .slot = 0 },
    };
    const cc_rows = [_]populate_core.ConstraintCombinatorDescription{
        .{ .slot = 0, .combinator_id = 4, .kind = 0, .element_count = 2, .elements = &first_elements },
        .{ .slot = 1, .combinator_id = 5, .kind = 1, .element_count = 1, .elements = &nested_elements },
    };
    var header = emptyTestImageHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = tv_rows.len;
    header.typevalues = &tv_rows;
    header.typedescriptors = &descs;
    header.protocoldescriptor_slot_count = 1;
    header.protocoldescriptor_descriptions = &pd_rows;
    header.constraintcombinator_slot_count = 2;
    header.constraintcombinator_descriptions = &cc_rows;

    var tv_slots = [_]?*const value_mod.TypeValue{ null, null };
    var pd_slots = [_]?*const value_mod.ProtocolDescriptor{null};
    var cc_slots = [_]?*const value_mod.ConstraintCombinator{ null, null };
    try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
        &handle,
        &header,
        @ptrCast(&tv_slots),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        @ptrCast(&pd_slots),
        @ptrCast(&cc_slots),
    ));

    try std.testing.expectEqual(@as(u32, 2), handle.image_constraintcombinator_slot_count);
    try std.testing.expectEqual(@as(?populate_core.ConstraintCombinatorSlotTable, @ptrCast(&cc_slots)), handle.image_constraintcombinator_slots);
    const first = cc_slots[0].?;
    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.intersection, first.kind);
    try std.testing.expectEqual(@as(u32, 4), first.combinator_id);
    try std.testing.expectEqual(tv_slots[1].?, first.elements[0].type);
    try std.testing.expectEqual(pd_slots[0].?, first.elements[1].protocol);
    const nested = cc_slots[1].?;
    try std.testing.expectEqual(value_mod.ConstraintCombinator.Kind.@"union", nested.kind);
    try std.testing.expectEqual(first, nested.elements[0].combinator);
}

test "freestanding loader rejects malformed synthetic images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };

    const descs = [_]populate_core.TypeDescriptor{std.mem.zeroes(populate_core.TypeDescriptor)};
    const bad_slot_rows = [_]populate_core.TypeValueRow{
        .{ .name = "alpha", .name_len = 5, .slot = 9, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
    };
    var header = emptyTestImageHeader();
    header.typevalue_slot_count = 2;
    header.typevalue_count = bad_slot_rows.len;
    header.typevalues = &bad_slot_rows;
    header.typedescriptors = &descs;

    var tv_slots = [_]?*const value_mod.TypeValue{ null, null };
    try std.testing.expectEqual(ONEZ_ERR_LOAD_FAILED, onez_load_runtime_image(
        &handle,
        &header,
        @ptrCast(&tv_slots),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    ));
    const slot_msg = onez_last_error(&handle) orelse return error.TestExpectedError;
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(slot_msg), "BadSlotIndex") != null);

    var bad_struct_desc = std.mem.zeroes(populate_core.TypeDescriptor);
    bad_struct_desc.kind = 3;
    bad_struct_desc.anon_struct_idx = 3;
    const bad_struct_descs = [_]populate_core.TypeDescriptor{bad_struct_desc};
    const rows = [_]populate_core.TypeValueRow{
        .{ .name = "alpha", .name_len = 5, .slot = 1, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
    };
    header.typevalue_count = rows.len;
    header.typevalues = &rows;
    header.typedescriptors = &bad_struct_descs;

    try std.testing.expectEqual(ONEZ_ERR_LOAD_FAILED, onez_load_runtime_image(
        &handle,
        &header,
        @ptrCast(&tv_slots),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    ));
    const struct_msg = onez_last_error(&handle) orelse return error.TestExpectedError;
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(struct_msg), "BadStructTypeIndex") != null);
}

test "freestanding loader leaves the handle untouched on a zero-count image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };

    var header = emptyTestImageHeader();
    try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
        &handle,
        &header,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    ));

    try std.testing.expectEqual(@as(?populate_core.SlotTable, null), handle.image_typevalue_slots);
    try std.testing.expectEqual(@as(u32, 0), handle.image_typevalue_slot_count);
    try std.testing.expectEqual(@as(?populate_core.ProtocolDescriptorSlotTable, null), handle.image_protocoldescriptor_slots);
    try std.testing.expectEqual(@as(u32, 0), handle.image_protocoldescriptor_slot_count);
    try std.testing.expectEqual(@as(?populate_core.ConstraintCombinatorSlotTable, null), handle.image_constraintcombinator_slots);
    try std.testing.expectEqual(@as(u32, 0), handle.image_constraintcombinator_slot_count);
}

fn fakeMethodBodyA(_: *JitContext) callconv(.c) i32 {
    return 0;
}

fn fakeMethodBodyB(_: *JitContext) callconv(.c) i32 {
    return 0;
}

fn dispatchTestRow(dispatch_id: u32, type_a_slot: u32, type_b_slot: u32, quotation_id: u32) populate_core.DispatchEntryDescription {
    return .{
        .dispatch_id = dispatch_id,
        .type_a_slot = type_a_slot,
        .type_b_slot = type_b_slot,
        .quotation_id = quotation_id,
        .module_name = null,
        .module_name_len = 0,
        .generic_name = null,
        .generic_name_len = 0,
        .body_bytecode = null,
        .body_bytecode_len = 0,
    };
}

test "freestanding replay registers compiled dispatch entries at the freeze-time dispatch id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };
    defer if (handle.method_dispatch) |*table| table.deinit();

    const descs = [_]populate_core.TypeDescriptor{
        std.mem.zeroes(populate_core.TypeDescriptor),
        std.mem.zeroes(populate_core.TypeDescriptor),
    };
    const tv_rows = [_]populate_core.TypeValueRow{
        .{ .name = "alpha", .name_len = 5, .slot = 1, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
        .{ .name = "beta", .name_len = 4, .slot = 2, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
    };
    const rows = [_]populate_core.DispatchEntryDescription{
        dispatchTestRow(7, 1, 2, 0),
        dispatchTestRow(9, 1, populate_core.dispatch_type_unary, 1),
        dispatchTestRow(9, populate_core.dispatch_type_any, populate_core.dispatch_type_unary, 0),
    };
    var header = emptyTestImageHeader();
    header.typevalue_slot_count = 3;
    header.typevalue_count = tv_rows.len;
    header.typevalues = &tv_rows;
    header.typedescriptors = &descs;
    header.dispatch_entry_slot_count = rows.len;
    header.dispatch_entry_descriptions = &rows;

    var tv_slots = [_]?*const value_mod.TypeValue{ null, null, null };
    try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
        &handle,
        &header,
        @ptrCast(&tv_slots),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    ));

    const quotations = [_]?*const anyopaque{ @ptrCast(&fakeMethodBodyA), @ptrCast(&fakeMethodBodyB) };
    try std.testing.expectEqual(@as(i32, ONEZ_OK), onez_runtime_register_quotations(&handle, &quotations, quotations.len));

    try std.testing.expectEqual(ONEZ_OK, onez_replay_method_dispatch(&handle));

    const alpha_desc = tv_slots[1].?.descriptor.?;
    const beta_desc = tv_slots[2].?.descriptor.?;
    const any_desc = handle.dispatch_any_sentinel.?.descriptor.?;
    const unary_desc = handle.dispatch_unary_sentinel.?.descriptor.?;
    const table = &handle.method_dispatch.?;

    const binary = table.lookupBinary(7, alpha_desc, beta_desc, any_desc).?;
    try std.testing.expectEqual(@intFromPtr(&fakeMethodBodyA), @intFromPtr(binary.body.quotation.code_ptr.?));

    const unary_exact = table.lookupUnary(9, alpha_desc, any_desc, unary_desc).?;
    try std.testing.expectEqual(@intFromPtr(&fakeMethodBodyB), @intFromPtr(unary_exact.body.quotation.code_ptr.?));

    const unary_wildcard = table.lookupUnary(9, beta_desc, any_desc, unary_desc).?;
    try std.testing.expectEqual(@intFromPtr(&fakeMethodBodyA), @intFromPtr(unary_wildcard.body.quotation.code_ptr.?));

    try std.testing.expect(table.lookupBinary(99, alpha_desc, beta_desc, any_desc) == null);
}

test "freestanding replay fails loudly on unresolvable rows" {
    const bad_rows = [_]struct {
        row: populate_core.DispatchEntryDescription,
        expect_msg: []const u8,
    }{
        .{
            .row = dispatchTestRow(7, 1, 1, populate_core.dispatch_interp_quotation_id_sentinel),
            .expect_msg = "dispatch id 7 carries an interpreter-run body",
        },
        .{
            .row = dispatchTestRow(8, 1, 1, 5),
            .expect_msg = "dispatch id 8 references missing compiled body 5",
        },
        .{
            .row = dispatchTestRow(9, 0, 1, 0),
            .expect_msg = "dispatch id 9 has unresolvable type slot 0",
        },
    };

    for (bad_rows) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var stack: [1]Value align(16) = undefined;
        var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };
        defer if (handle.method_dispatch) |*table| table.deinit();

        const descs = [_]populate_core.TypeDescriptor{std.mem.zeroes(populate_core.TypeDescriptor)};
        const tv_rows = [_]populate_core.TypeValueRow{
            .{ .name = "alpha", .name_len = 5, .slot = 1, .descriptor = null, .member_type_slots = null, .member_type_count = 0 },
        };
        const rows = [_]populate_core.DispatchEntryDescription{case.row};
        var header = emptyTestImageHeader();
        header.typevalue_slot_count = 2;
        header.typevalue_count = tv_rows.len;
        header.typevalues = &tv_rows;
        header.typedescriptors = &descs;
        header.dispatch_entry_slot_count = rows.len;
        header.dispatch_entry_descriptions = &rows;

        var tv_slots = [_]?*const value_mod.TypeValue{ null, null };
        try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
            &handle,
            &header,
            @ptrCast(&tv_slots),
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
        ));

        const quotations = [_]?*const anyopaque{@ptrCast(&fakeMethodBodyA)};
        try std.testing.expectEqual(@as(i32, ONEZ_OK), onez_runtime_register_quotations(&handle, &quotations, quotations.len));

        try std.testing.expectEqual(ONEZ_ERR_LOAD_FAILED, onez_replay_method_dispatch(&handle));
        const msg = onez_last_error(&handle) orelse return error.TestExpectedError;
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(msg), case.expect_msg) != null);
    }
}

test "freestanding replay no-ops on a zero-entry image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stack: [1]Value align(16) = undefined;
    var handle = OnezHandle{ .allocator = arena.allocator(), .stack = stack[0..] };

    var header = emptyTestImageHeader();
    try std.testing.expectEqual(ONEZ_OK, onez_load_runtime_image(
        &handle,
        &header,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    ));

    try std.testing.expectEqual(ONEZ_OK, onez_replay_method_dispatch(&handle));
    try std.testing.expect(handle.method_dispatch == null);
    try std.testing.expect(handle.dispatch_any_sentinel == null);
}
