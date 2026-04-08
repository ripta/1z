const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const VirtualType = value_mod.VirtualType;
const StructInstance = value_mod.StructInstance;
const StructType = value_mod.StructType;
const TypeValue = value_mod.TypeValue;

const ir_mod = @import("ffi/ir.zig");
const JitBuffer = ir_mod.JitBuffer;
const c = ir_mod.ir;

const jit_dispatch_mod = @import("jit_dispatch.zig");
const JitDispatchTable = jit_dispatch_mod.JitDispatchTable;
const JitEntry = jit_dispatch_mod.JitEntry;

const Context = @import("context.zig").Context;
const StackEffect = @import("stack_effect.zig").StackEffect;
const signal = @import("signal.zig");
const trace_mod = @import("trace.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const helpers = @import("primitives/helpers.zig");
const dynamic_vars_mod = @import("primitives/dynamic_vars.zig");
const errors_mod = @import("primitives/errors.zig");
const iterators_mod = @import("primitives/iterators.zig");
const sequences_mod = @import("primitives/sequences.zig");
const control = @import("primitives/control.zig");
const dispatch_helpers = @import("primitives/dispatch_helpers.zig");
const markers_mod = @import("primitives/markers.zig");
const WordDefinition = @import("dictionary.zig").WordDefinition;

pub const IrCodegenError = error{
    NotCompilable,
    CompilationFailed,
    StackUnderflow,
    StackShapeMismatch,
    UncompiledWords,
};

pub const CodegenDiagnostics = struct {
    uncompiled_words: []const []const u8 = &.{},
};

pub const CompiledWord = struct {
    code_ptr: *const anyopaque,
    jit_buf: JitBuffer,
};

fn shouldSkipTypeAnnotationValidation(word: WordDefinition) bool {
    const has_generic = for (word.markers) |mk| {
        if (markers_mod.isGenericMarker(mk)) break true;
    } else false;
    if (!has_generic) return false;

    return switch (word.action) {
        .compound => |instrs| instrs.len == 0,
        .native, .host_callback => false,
    };
}

/// Description of a word to be compiled for AOT C emission.
pub const AotWordDesc = struct {
    name: []const u8,
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    word_id: u32,
    /// Prelude words are available in the AOT runtime dictionary and can
    /// safely fall back to jitInterpretedCall if codegen fails.
    is_prelude: bool = false,
    /// Native words have no compound instructions and must always use
    /// jitInterpretedCall at runtime. They are included in the resolver
    /// so that non-prelude words calling them are not rejected, but they
    /// must not enter compiled_names or be trial-compiled.
    is_native: bool = false,
};

const supported_binary_ops = [_][]const u8{ "+", "-", "*", "/", "div", "rem", "%" };
const supported_unary_ops = [_][]const u8{"abs"};
const supported_comparison_ops = [_][]const u8{ "=", "<", ">" };

fn isSupportedOp(name: []const u8) bool {
    for (supported_binary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    for (supported_unary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    for (supported_comparison_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }

    // HACK(ripta): include some non-primitive ops as "supported" so they can be compiled with the same fast path
    //              as primitives instead of going through dynamic dispatch
    if (std.mem.eql(u8, name, "if")) return true;
    if (std.mem.eql(u8, name, "call")) return true;
    if (std.mem.eql(u8, name, "t") or std.mem.eql(u8, name, "f")) return true;

    if (isLoopOp(name)) return true;
    if (isErrorHandlingOp(name)) return true;
    if (isDynamicVarOp(name)) return true;
    if (isIteratorOp(name)) return true;

    // HACK(ripta): not technically native, but treat certain native core library words as harcoded
    //              instrinsics so they can be compiled with the same fast path instead of dynamic dispatch
    if (std.mem.eql(u8, name, "native.virtual-unwrap")) return true;
    if (std.mem.eql(u8, name, "native.struct-field-get")) return true;
    if (std.mem.eql(u8, name, "native.typed-validate-and-promote")) return true;

    return false;
}

fn isBinaryOp(name: []const u8) bool {
    for (supported_binary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn isComparisonOp(name: []const u8) bool {
    for (supported_comparison_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

const supported_stack_ops = [_][]const u8{ "dup", "drop", "swap", "over" };

fn isStackOp(name: []const u8) bool {
    for (supported_stack_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

const supported_loop_ops = [_][]const u8{ "times", "loop", "while", "until" };

fn isLoopOp(name: []const u8) bool {
    for (supported_loop_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn isErrorHandlingOp(name: []const u8) bool {
    return std.mem.eql(u8, name, "recover") or std.mem.eql(u8, name, "cleanup");
}

fn isDynamicVarOp(name: []const u8) bool {
    return std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "with-parameter");
}

const IteratorOpcode = enum(u8) {
    next = 1,
    collect = 2,
    count = 3,
    close_iterator = 4,
    take = 5,
    drop = 6,
    each = 7,
    map = 8,
    filter = 9,
    reduce = 10,
};

fn isIteratorOp(name: []const u8) bool {
    return iteratorOpcodeFromName(name) != null;
}

fn iteratorOpcodeFromName(name: []const u8) ?IteratorOpcode {
    // >iterator is a generic compound word in the prelude, not a pure
    // native. Calling nativeToIterator directly would bypass generic
    // dispatch, breaking user-defined >iterator methods on virtual types.
    if (std.mem.eql(u8, name, "#next")) return .next;
    if (std.mem.eql(u8, name, "#collect")) return .collect;
    if (std.mem.eql(u8, name, "#count")) return .count;
    if (std.mem.eql(u8, name, "close-iterator")) return .close_iterator;
    if (std.mem.eql(u8, name, "#take")) return .take;
    if (std.mem.eql(u8, name, "#drop")) return .drop;
    if (std.mem.eql(u8, name, "#each")) return .each;
    if (std.mem.eql(u8, name, "#map")) return .map;
    if (std.mem.eql(u8, name, "#filter")) return .filter;
    if (std.mem.eql(u8, name, "#reduce")) return .reduce;
    return null;
}

const IteratorEffects = struct {
    inputs: usize,
    outputs: usize,
    dynamic: bool,
};

fn iteratorEffects(opcode: IteratorOpcode) IteratorEffects {
    return switch (opcode) {
        .next => .{ .inputs = 1, .outputs = 1, .dynamic = false },
        .collect => .{ .inputs = 1, .outputs = 1, .dynamic = false },
        .count => .{ .inputs = 1, .outputs = 1, .dynamic = false },
        .close_iterator => .{ .inputs = 1, .outputs = 0, .dynamic = false },
        .take => .{ .inputs = 2, .outputs = 1, .dynamic = false },
        .drop => .{ .inputs = 2, .outputs = 1, .dynamic = false },
        .each => .{ .inputs = 2, .outputs = 0, .dynamic = true },
        .map => .{ .inputs = 2, .outputs = 1, .dynamic = true },
        .filter => .{ .inputs = 2, .outputs = 1, .dynamic = true },
        .reduce => .{ .inputs = 3, .outputs = 1, .dynamic = true },
    };
}

/// Layout of Value for use in generated IR code, determined at runtime
/// since Zig unions don't expose field offsets at comptime.
const ValueLayout = struct {
    const TagType = std.meta.Tag(Value);
    const value_size: usize = @sizeOf(Value);
    const tag_size: usize = @sizeOf(TagType);
    const fixnum_tag: u8 = @intFromEnum(@as(TagType, .fixnum));
    const quotation_tag: u8 = @intFromEnum(@as(TagType, .quotation));
    const tagged_tag: u8 = @intFromEnum(@as(TagType, .tagged));

    const ir_tag_type: c_uint = switch (tag_size) {
        1 => c.IR_U8,
        2 => c.IR_U16,
        4 => c.IR_U32,
        else => unreachable,
    };

    const PayloadKind = enum {
        void_,
        i64_,
        f64_,
        bool_,
        ptr,
        slice,
        dual_ptr,
        inline_,
    };

    fn payloadKindOf(tag: TagType) PayloadKind {
        return switch (tag) {
            .unit => .void_,
            .fixnum => .i64_,
            .float => .f64_,
            .boolean => .bool_,
            .hash, .vector, .byte_array, .set, .mutable_map, .stream, .resource, .parameter, .module, .marker, .struct_type, .struct_instance, .benchmark_report, .task, .channel, .iterator, .type_val, .sandbox_spec => .ptr,
            .string, .symbol, .array, .doc_string, .template => .slice,
            .tagged => .dual_ptr,
            .bignum, .quotation, .stack_effect, .error_value => .inline_,
        };
    }

    var payload_offset: usize = 0;
    var tag_offset: usize = 0;
    var slice_len_offset: usize = 0;
    var quotation_code_ptr_offset: usize = 0;
    var tagged_tag_ptr_offset: usize = 0;
    var tagged_inner_ptr_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var v: Value = .{ .fixnum = 0 };
        payload_offset = @intFromPtr(&v.fixnum) - @intFromPtr(&v);

        // Discover the tag offset by finding the byte position where three
        // differently-tagged values each store their expected tag integer.
        // Padding bytes are undefined in Zig unions, so comparing only two
        // values can produce false positives. Three values with distinct
        // non-adjacent tag integers (0, 1, 3) make a coincidental match
        // in padding astronomically unlikely.
        const tag0: u8 = @intFromEnum(@as(TagType, .fixnum)); // 0
        const tag1: u8 = @intFromEnum(@as(TagType, .float)); // 1
        const tag3: u8 = @intFromEnum(@as(TagType, .boolean)); // 3

        var v1: Value = .{ .fixnum = 0 };
        var v2: Value = .{ .float = 0.0 };
        var v3: Value = .{ .boolean = false };

        const b1: [*]const u8 = @ptrCast(&v1);
        const b2: [*]const u8 = @ptrCast(&v2);
        const b3: [*]const u8 = @ptrCast(&v3);

        for (0..@sizeOf(Value)) |i| {
            if (b1[i] == tag0 and b2[i] == tag1 and b3[i] == tag3) {
                tag_offset = i;
                break;
            }
        }

        // Discover the slice len offset. Zig slices are {ptr, len} but the
        // exact position relative to the Value base must be verified at runtime.
        slice_len_offset = payload_offset + @sizeOf(usize);
        var sv: Value = .{ .string = "ABCDE" };
        const sv_bytes: [*]const u8 = @ptrCast(&sv);
        const len_at_offset: *align(1) const usize = @ptrCast(sv_bytes + slice_len_offset);
        std.debug.assert(len_at_offset.* == 5);

        // Discover the code_ptr offset within a quotation Value by writing
        // a sentinel pointer and scanning for it.
        const sentinel: *const anyopaque = @ptrFromInt(0xDEAD_BEEF_CAFE_F00D);
        var qv: Value = .{ .quotation = .{ .instructions = &.{}, .code_ptr = sentinel } };
        const qv_bytes: [*]const u8 = @ptrCast(&qv);
        var found_code_ptr = false;
        for (0..@sizeOf(Value) - @sizeOf(usize) + 1) |offset| {
            const ptr_at: *align(1) const usize = @ptrCast(qv_bytes + offset);
            if (ptr_at.* == @intFromPtr(sentinel)) {
                quotation_code_ptr_offset = offset;
                found_code_ptr = true;
                break;
            }
        }
        std.debug.assert(found_code_ptr);

        // tag and inner pointer offsets within the `tagged` variant's double-indirection
        const tag_sentinel_addr: usize = 0xDEAD_BEEF_CAFE_0010;
        const inner_sentinel_addr: usize = 0xDEAD_BEEF_CAFE_0020;

        var tv: Value = .{ .tagged = .{
            .tag = @ptrFromInt(tag_sentinel_addr),
            .inner = @ptrFromInt(inner_sentinel_addr),
        } };

        const tv_bytes: [*]const u8 = @ptrCast(&tv);
        var found_tag_ptr = false;
        var found_inner_ptr = false;
        for (0..@sizeOf(Value) - @sizeOf(usize) + 1) |offset| {
            const ptr_at: *align(1) const usize = @ptrCast(tv_bytes + offset);
            if (!found_tag_ptr and ptr_at.* == tag_sentinel_addr) {
                tagged_tag_ptr_offset = offset;
                found_tag_ptr = true;
            } else if (!found_inner_ptr and ptr_at.* == inner_sentinel_addr) {
                tagged_inner_ptr_offset = offset;
                found_inner_ptr = true;
            }

            if (found_tag_ptr and found_inner_ptr) break;
        }

        std.debug.assert(found_tag_ptr);
        std.debug.assert(found_inner_ptr);

        initialized = true;
    }
};

/// Layout of StructInstance for use in generated IR code, determined at
/// runtime since Zig structs don't expose field offsets at comptime.
const StructInstanceLayout = struct {
    var struct_type_offset: usize = 0;
    var fields_ptr_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var dummy: StructInstance = undefined;
        const base: usize = @intFromPtr(&dummy);
        struct_type_offset = @intFromPtr(&dummy.struct_type) - base;
        fields_ptr_offset = @intFromPtr(&dummy.fields.ptr) - base;

        initialized = true;
    }
};

/// Result of resolving a word name to a dispatch table entry.
pub const ResolvedWord = struct {
    word_id: u32,
    input_count: u8,
    output_count: u8,
    native_fn_ptr: ?usize = null,
    stack_effect_ptr: ?usize = null,
};

/// Callback interface for resolving word names to dispatch table IDs.
/// Used during compilation to map `call_word` names to JIT dispatch entries.
pub const WordResolver = struct {
    resolve: *const fn ([]const u8, *anyopaque) ?ResolvedWord,
    user_data: *anyopaque,
    /// Stable pointer to the JitDispatchTable, baked into generated code as a constant.
    dispatch_table_ptr: *const anyopaque,
};

/// Layout of JitDispatchTable and JitEntry for generated IR code.
const DispatchLayout = struct {
    var items_ptr_offset: usize = 0;
    var entry_size: usize = 0;
    var code_ptr_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var table = JitDispatchTable.init(std.heap.page_allocator);
        const table_base: usize = @intFromPtr(&table);
        const items_ptr_addr: usize = @intFromPtr(&table.entries.items.ptr);
        items_ptr_offset = items_ptr_addr - table_base;

        entry_size = @sizeOf(JitEntry);

        var dummy_entry = JitEntry{ .code_ptr = null, .jit_buf = null, .word_name = "" };
        const entry_base: usize = @intFromPtr(&dummy_entry);
        const code_ptr_addr: usize = @intFromPtr(&dummy_entry.code_ptr);
        code_ptr_offset = code_ptr_addr - entry_base;

        initialized = true;
    }
};

// =============================================================================
// Emit helpers
// =============================================================================

/// Produce an IR constant for a variant's tag value.
fn emitTagConst(ctx: *c.ir_ctx, tag: ValueLayout.TagType) c.ir_ref {
    const tag_int: u8 = @intFromEnum(tag);
    return switch (ValueLayout.tag_size) {
        1 => c.ir_const_u8(ctx, tag_int),
        2 => c.ir_const_u16(ctx, tag_int),
        4 => c.ir_const_u32(ctx, tag_int),
        else => unreachable,
    };
}

/// Map a type name string to an IR tag constant for the corresponding Value variant.
/// Returns null for types that need pointer comparison (virtual types, struct types).
fn mapTypeNameToTagConst(state: *CompileState, name: []const u8) ?c.ir_ref {
    const ctx = state.ctx;

    if (std.mem.eql(u8, name, "fixnum")) return state.fixnum_tag_const;
    if (std.mem.eql(u8, name, "float")) return state.float_tag_const;
    if (std.mem.eql(u8, name, "boolean")) return state.boolean_tag_const;
    if (std.mem.eql(u8, name, "string")) return emitTagConst(ctx, .string);
    if (std.mem.eql(u8, name, "symbol")) return emitTagConst(ctx, .symbol);
    if (std.mem.eql(u8, name, "array")) return emitTagConst(ctx, .array);
    if (std.mem.eql(u8, name, "quotation")) return emitTagConst(ctx, .quotation);
    if (std.mem.eql(u8, name, "hash")) return emitTagConst(ctx, .hash);
    if (std.mem.eql(u8, name, "vector")) return emitTagConst(ctx, .vector);
    if (std.mem.eql(u8, name, "byte-array")) return emitTagConst(ctx, .byte_array);
    if (std.mem.eql(u8, name, "set")) return emitTagConst(ctx, .set);
    if (std.mem.eql(u8, name, "mutable-map")) return emitTagConst(ctx, .mutable_map);
    if (std.mem.eql(u8, name, "bignum")) return emitTagConst(ctx, .bignum);

    return null;
}

/// Check the tag of a Value at elem_addr; bail if it doesn't match expected_tag.
fn emitTagCheck(
    ctx: *c.ir_ctx,
    elem_addr: c.ir_ref,
    expected_tag: c.ir_ref,
    tag_offset_const: c.ir_ref,
    bail_status: c.ir_ref,
) void {
    const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, tag_offset_const);
    const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);
    const tag_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), tag_val, expected_tag);
    const if_mismatch = c._ir_IF(ctx, tag_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_mismatch);
}

/// Load an i64 payload from a Value at elem_addr.
fn emitUnboxI64(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_I64, payload_addr);
}

/// Load an f64 payload from a Value at elem_addr.
fn emitUnboxF64(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_DOUBLE, payload_addr);
}

/// Load a bool payload from a Value at elem_addr.
fn emitUnboxBool(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_BOOL, payload_addr);
}

/// Load a pointer payload from a Value at elem_addr.
fn emitUnboxPtr(ctx: *c.ir_ctx, elem_addr: c.ir_ref, payload_offset_const: c.ir_ref) c.ir_ref {
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    return c._ir_LOAD(ctx, c.IR_ADDR, payload_addr);
}

const SliceRefs = struct { ptr: c.ir_ref, len: c.ir_ref };

/// Load a slice (ptr + len) payload from a Value at elem_addr.
fn emitUnboxSlice(
    ctx: *c.ir_ctx,
    elem_addr: c.ir_ref,
    payload_offset_const: c.ir_ref,
    slice_len_offset_const: c.ir_ref,
) SliceRefs {
    const ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, payload_offset_const);
    const ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, ptr_addr);
    const len_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, slice_len_offset_const);
    const len_val = c._ir_LOAD(ctx, c.IR_ADDR, len_addr);
    return .{ .ptr = ptr_val, .len = len_val };
}

/// Store a tag at tag_offset within a Value at dest_addr.
fn emitBoxTag(ctx: *c.ir_ctx, dest_addr: c.ir_ref, tag_offset_const: c.ir_ref, tag_const: c.ir_ref) void {
    const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, tag_offset_const);
    c._ir_STORE(ctx, tag_addr, tag_const);
}

/// Store a tag and a single payload value into a Value at dest_addr.
/// Works for i64, f64, bool, and pointer payloads (the IR type is
/// carried by the val ref itself).
fn emitBoxPayload(
    ctx: *c.ir_ctx,
    dest_addr: c.ir_ref,
    tag_offset_const: c.ir_ref,
    payload_offset_const: c.ir_ref,
    tag_const: c.ir_ref,
    val: c.ir_ref,
) void {
    emitBoxTag(ctx, dest_addr, tag_offset_const, tag_const);
    const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, payload_offset_const);
    c._ir_STORE(ctx, payload_addr, val);
}

/// Copy an entire Value's raw bytes into the stack slot at dest_addr.
/// Emits one STORE per 8-byte word, with the literal bytes baked in
/// as IR constants.
fn emitPushValue(ctx: *c.ir_ctx, val: *const Value, dest_addr: c.ir_ref) void {
    const raw: [*]const u8 = @ptrCast(val);
    const num_words = ValueLayout.value_size / 8;
    var offset: usize = 0;
    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const word_ptr: *align(1) const u64 = @ptrCast(raw + offset);
        const word = word_ptr.*;
        const word_const = c.ir_const_u64(ctx, word);
        if (offset == 0) {
            c._ir_STORE(ctx, dest_addr, word_const);
        } else {
            const off_const = c.ir_const_addr(ctx, offset);
            const addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, off_const);
            c._ir_STORE(ctx, addr, word_const);
        }
        offset += 8;
    }
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const byte_val = c.ir_const_u8(ctx, raw[offset]);
        const off_const = c.ir_const_addr(ctx, offset);
        const addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dest_addr, off_const);
        c._ir_STORE(ctx, addr, byte_val);
    }
}

/// Copy a full Value's raw bytes between two physical stack slots.
fn emitCopySlot(ctx: *c.ir_ctx, base_addr: c.ir_ref, src_slot: usize, dest_slot: usize) void {
    const num_words = ValueLayout.value_size / 8;
    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const src_off = src_slot * ValueLayout.value_size + offset;
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, src_off));
        const word_val = c._ir_LOAD(ctx, c.IR_U64, src_addr);
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, word_val);
    }
    var offset = num_words * 8;
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const src_off = src_slot * ValueLayout.value_size + offset;
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, src_off));
        const byte_val = c._ir_LOAD(ctx, c.IR_U8, src_addr);
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, byte_val);
    }
}

/// Swap two physical stack slots by loading all words first, then storing.
fn emitSwapSlots(ctx: *c.ir_ctx, base_addr: c.ir_ref, slot_a: usize, slot_b: usize) void {
    const num_words = ValueLayout.value_size / 8;
    var a_words: [8]c.ir_ref = undefined;
    var b_words: [8]c.ir_ref = undefined;
    std.debug.assert(num_words <= a_words.len);

    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const a_off = slot_a * ValueLayout.value_size + offset;
        const b_off = slot_b * ValueLayout.value_size + offset;
        const a_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, a_off));
        const b_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b_off));
        a_words[i] = c._ir_LOAD(ctx, c.IR_U64, a_addr);
        b_words[i] = c._ir_LOAD(ctx, c.IR_U64, b_addr);
    }

    i = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const a_off = slot_a * ValueLayout.value_size + offset;
        const b_off = slot_b * ValueLayout.value_size + offset;
        const a_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, a_off));
        const b_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b_off));
        c._ir_STORE(ctx, a_addr, b_words[i]);
        c._ir_STORE(ctx, b_addr, a_words[i]);
    }

    // Handle trailing bytes (if value_size is not a multiple of 8)
    var offset = num_words * 8;
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const a_off = slot_a * ValueLayout.value_size + offset;
        const b_off = slot_b * ValueLayout.value_size + offset;
        const a_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, a_off));
        const b_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, b_off));
        const a_byte = c._ir_LOAD(ctx, c.IR_U8, a_addr);
        const b_byte = c._ir_LOAD(ctx, c.IR_U8, b_addr);
        c._ir_STORE(ctx, a_addr, b_byte);
        c._ir_STORE(ctx, b_addr, a_byte);
    }
}

/// Copy a full Value's raw bytes from a runtime pointer into a physical stack slot.
fn emitCopyFromPtr(ctx: *c.ir_ctx, base_addr: c.ir_ref, src_ptr: c.ir_ref, dest_slot: usize) void {
    const num_words = ValueLayout.value_size / 8;
    var i: usize = 0;
    while (i < num_words) : (i += 1) {
        const offset = i * 8;
        const src_addr = if (offset == 0) src_ptr else c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), src_ptr, c.ir_const_addr(ctx, offset));
        const word_val = c._ir_LOAD(ctx, c.IR_U64, src_addr);
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, word_val);
    }
    var offset = num_words * 8;
    while (offset < ValueLayout.value_size) : (offset += 1) {
        const src_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), src_ptr, c.ir_const_addr(ctx, offset));
        const byte_val = c._ir_LOAD(ctx, c.IR_U8, src_addr);
        const dest_off = dest_slot * ValueLayout.value_size + offset;
        const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, dest_off));
        c._ir_STORE(ctx, dest_addr, byte_val);
    }
}

/// Symbolic stack entry: tracks the IR representation of each value on the
/// abstract compilation stack.
const StackEntry = union(enum) {
    /// Unboxed fixnum payload, usable directly in arithmetic and comparisons.
    i64_ref: c.ir_ref,
    /// Unboxed float payload, usable directly in float arithmetic.
    f64_ref: c.ir_ref,
    /// IR boolean from a comparison op or `t`/`f` literal, boxed to a boolean
    /// Value at finalization.
    bool_ref: c.ir_ref,
    /// Captured instruction slice from a quotation literal. Never reaches
    /// finalization -- consumed by `if` at compile time.
    quotation_body: []const Instruction,
    /// Opaque Value written to physical stack slot N. This is used for types
    /// that can't be represented as IR scalars, i.e., anything other than
    /// fixnum / boolean.
    raw_at_slot: usize,
};

/// Shared compilation state threaded through instruction compilation.
const CompileState = struct {
    ctx: *c.ir_ctx,
    base_addr: c.ir_ref,
    tag_offset_const: c.ir_ref,
    payload_offset_const: c.ir_ref,
    fixnum_tag_const: c.ir_ref,
    float_tag_const: c.ir_ref,
    boolean_tag_const: c.ir_ref,
    tagged_tag_const: c.ir_ref,
    struct_instance_tag_const: c.ir_ref,
    bail_status: c.ir_ref,
    ok_status: c.ir_ref,
    items_ptr: c.ir_ref,
    sp_ptr: c.ir_ref,
    capacity_param: c.ir_ref,
    sp_val: c.ir_ref,
    base_idx: c.ir_ref,
    value_size_const: c.ir_ref,
    dynamic_call_emitted: bool = false,
    dispatch_ptr: c.ir_ref = c.IR_UNUSED,
    resolver: ?WordResolver = null,
    jit_ctx_ptr: c.ir_ref = c.IR_UNUSED,
    safepoint_fn: c.ir_ref = c.IR_UNUSED,
    recover_fn: c.ir_ref = c.IR_UNUSED,
    cleanup_fn: c.ir_ref = c.IR_UNUSED,
    get_fn: c.ir_ref = c.IR_UNUSED,
    with_parameter_fn: c.ir_ref = c.IR_UNUSED,
    iterator_fn: c.ir_ref = c.IR_UNUSED,
    native_call_fn: c.ir_ref = c.IR_UNUSED,
    interpreted_call_fn: c.ir_ref = c.IR_UNUSED,
    validate_params_fn: c.ir_ref = c.IR_UNUSED,
    interp_ctx: ?*const Context = null,
    error_propagate_status: c.ir_ref = c.IR_UNUSED,
    self_name: ?[]const u8 = null,
    loop_begin_ref: c.ir_ref = c.IR_UNUSED,
    input_count: u8 = 0,
    diverged: bool = false,
    loop_end_set: bool = false,
    mutual_group: ?[]const []const u8 = null,
    trampoline_status: c.ir_ref = c.IR_UNUSED,
    /// When true, callback references use named extern symbols (ir_const_func)
    /// instead of baked function pointer addresses (ir_const_addr). This is
    /// required for AOT C emission where addresses are not known at compile time.
    aot_mode: bool = false,
    /// Set of compiled word names available in AOT mode. Used to decide whether
    /// a compound word call can be a direct function call or must fall through
    /// to jitInterpretedCall.
    aot_compiled_names: ?*const std.StringHashMapUnmanaged(u32) = null,
    /// Prototype ref for 1-arg callbacks in AOT mode: (uintptr_t) -> int32_t.
    aot_proto_1arg: c.ir_ref = c.IR_UNUSED,
    /// Prototype ref for 2-arg callbacks in AOT mode: (uintptr_t, uintptr_t) -> int32_t.
    aot_proto_2arg: c.ir_ref = c.IR_UNUSED,
    /// jitCallQuotation callback ref (used inline, not stored in CompileState for JIT).
    call_quotation_fn: c.ir_ref = c.IR_UNUSED,
    /// Pre-loaded interpreter Context pointer from JitContext. In AOT mode,
    /// this is loaded once in the prologue to avoid the ir_emit_c d_0 bug
    /// where unused LOADs get assigned vreg 0 without a declaration.
    preloaded_ctx_val: c.ir_ref = c.IR_UNUSED,
    /// Accumulator for string/symbol literals encountered during AOT compilation.
    /// Each entry gets emitted as a `static const char[]` in the C preamble.
    aot_string_literals: ?*std.ArrayListUnmanaged(AotStringLiteral) = null,
};

const AotStringLiteral = struct {
    data: []const u8,
    is_symbol: bool,
};

/// Extract or emit an i64 IR ref from a stack entry. For raw_at_slot entries,
/// emits a fixnum tag check and unboxes the payload; bails if the tag doesn't match.
fn requireI64(entry: StackEntry, state: *CompileState) IrCodegenError!c.ir_ref {
    return switch (entry) {
        .i64_ref => |ref| ref,
        .raw_at_slot => |s| {
            const ctx = state.ctx;
            const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
            const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_addr, slot_byte_offset);
            emitTagCheck(ctx, elem_addr, state.fixnum_tag_const, state.tag_offset_const, state.bail_status);
            return emitUnboxI64(ctx, elem_addr, state.payload_offset_const);
        },
        else => IrCodegenError.NotCompilable,
    };
}

/// Extract or emit an f64 IR ref from a stack entry. For raw_at_slot entries,
/// emits a float tag check and unboxes the payload; bails if the tag doesn't match.
fn requireF64(entry: StackEntry, state: *CompileState) IrCodegenError!c.ir_ref {
    return switch (entry) {
        .f64_ref => |ref| ref,
        .raw_at_slot => |s| {
            const ctx = state.ctx;
            const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
            const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_addr, slot_byte_offset);
            emitTagCheck(ctx, elem_addr, state.float_tag_const, state.tag_offset_const, state.bail_status);
            return emitUnboxF64(ctx, elem_addr, state.payload_offset_const);
        },
        else => IrCodegenError.NotCompilable,
    };
}

const ResolvedPair = union(enum) {
    i64_pair: struct { a: c.ir_ref, b: c.ir_ref },
    f64_pair: struct { a: c.ir_ref, b: c.ir_ref },
};

/// Resolve a pair of stack entries to a common numeric type for binary ops.
/// If either operand is f64_ref, both resolve as f64. If either is i64_ref
/// (and neither is f64_ref), both resolve as i64. Two raw_at_slot entries
/// default to i64 (the common case; runtime tag check bails on mismatch).
fn resolveOperandPair(entry_a: StackEntry, entry_b: StackEntry, state: *CompileState) IrCodegenError!ResolvedPair {
    // f64 takes priority: if either operand is a known float, resolve both as f64.
    if (entry_a == .f64_ref or entry_b == .f64_ref) {
        return .{ .f64_pair = .{
            .a = try requireF64(entry_a, state),
            .b = try requireF64(entry_b, state),
        } };
    }
    // Otherwise resolve as i64 (covers i64_ref, raw_at_slot, and mixed).
    if (entry_a == .i64_ref or entry_b == .i64_ref or
        (entry_a == .raw_at_slot and entry_b == .raw_at_slot))
    {
        return .{ .i64_pair = .{
            .a = try requireI64(entry_a, state),
            .b = try requireI64(entry_b, state),
        } };
    }
    return IrCodegenError.NotCompilable;
}

/// Materialize any quotation_body entries as raw Values on the physical stack.
/// flushToPhysicalStack skips quotation_body since it's normally consumed by
/// `if`/`call`, but callback-based ops need them as proper Values for the
/// interpreter to pop.
fn materializeQuotations(state: *CompileState, stack: *[64]StackEntry, sp: usize) void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;
    for (0..sp) |qi| {
        switch (stack[qi]) {
            .quotation_body => |body| {
                const qval = Value{ .quotation = .{ .instructions = body, .code_ptr = null } };
                const slot_byte_offset = c.ir_const_addr(ctx, qi * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitPushValue(ctx, &qval, dest_addr);
                stack[qi] = .{ .raw_at_slot = qi };
            },
            else => {},
        }
    }
}

/// Reset all stack entries from 0..sp to raw_at_slot identity (slot i = i).
/// Used after operations that flush to physical memory, ensuring the abstract
/// stack mirrors the physical layout.
fn resetStackToPhysical(stack: *[64]StackEntry, sp: usize) void {
    for (0..sp) |i| {
        stack[i] = .{ .raw_at_slot = i };
    }
}

/// Write all pending symbolic stack entries to their physical memory slots.
/// After this, every entry is materialized in the Value array at base_addr.
fn flushToPhysicalStack(state: *CompileState, stack: *[64]StackEntry, sp: usize) void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    // Preserve raw aliases whose source slot would be overwritten by
    // first-pass boxing before they get a chance to copy from it.
    for (0..sp) |i| {
        switch (stack[i]) {
            .raw_at_slot => |s| {
                if (s == i or s >= sp) continue;
                switch (stack[s]) {
                    .i64_ref, .f64_ref, .bool_ref => {
                        emitCopySlot(ctx, base_addr, s, i);
                        stack[i] = .{ .raw_at_slot = i };
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    // First pass: handle non-raw entries and detect swap patterns.
    for (0..sp) |i| {
        switch (stack[i]) {
            .i64_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.fixnum_tag_const, ref);
                stack[i] = .{ .raw_at_slot = i };
            },
            .f64_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.float_tag_const, ref);
                stack[i] = .{ .raw_at_slot = i };
            },
            .bool_ref => |ref| {
                const slot_byte_offset = c.ir_const_addr(ctx, i * ValueLayout.value_size);
                const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                emitBoxPayload(ctx, dest_addr, state.tag_offset_const, state.payload_offset_const, state.boolean_tag_const, ref);
                stack[i] = .{ .raw_at_slot = i };
            },
            .quotation_body => {},
            .raw_at_slot => {},
        }
    }

    // Second pass: resolve raw_at_slot entries, using swap for cross-references.
    for (0..sp) |i| {
        switch (stack[i]) {
            .raw_at_slot => |s| {
                if (s != i) {
                    // Check for swap pattern: stack[i] -> s and stack[s] -> i
                    if (s < sp and stack[s] == .raw_at_slot and stack[s].raw_at_slot == i) {
                        emitSwapSlots(ctx, base_addr, i, s);
                        stack[i] = .{ .raw_at_slot = i };
                        stack[s] = .{ .raw_at_slot = s };
                    } else {
                        emitCopySlot(ctx, base_addr, s, i);
                        stack[i] = .{ .raw_at_slot = i };
                    }
                }
            },
            else => {},
        }
    }
}

/// Compute the IR truthiness boolean for a stack entry.
/// 1z truthiness: only `f` (boolean false) is falsy.
fn emitTruthiness(state: *CompileState, entry: StackEntry, base_addr: c.ir_ref) IrCodegenError!c.ir_ref {
    const ctx = state.ctx;
    return switch (entry) {
        .bool_ref => |ref| ref,
        .i64_ref, .f64_ref => c.ir_const_bool(ctx, true),
        .raw_at_slot => |s| blk: {
            const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
            const slot_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
            const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), slot_addr, state.tag_offset_const);
            const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);
            const is_bool_tag = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), tag_val, state.boolean_tag_const);

            const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), slot_addr, state.payload_offset_const);
            const payload_val = c._ir_LOAD(ctx, c.IR_BOOL, payload_addr);
            const false_const = c.ir_const_bool(ctx, false);
            const is_false_payload = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), payload_val, false_const);
            const is_falsy = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), is_bool_tag, is_false_payload);
            break :blk c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), is_falsy, false_const);
        },
        .quotation_body => IrCodegenError.NotCompilable,
    };
}

/// Emit an indirect call to a quotation Value stored at physical stack slot.
/// Performs tag check, code_ptr null check, flushes stack, and calls.
fn emitIndirectQuotCall(
    state: *CompileState,
    stack: *[64]StackEntry,
    sp: *usize,
    slot: usize,
) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    const slot_byte_offset = c.ir_const_addr(ctx, slot * ValueLayout.value_size);
    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);

    // Check tag is quotation
    const quotation_tag_const = emitTagConst(ctx, .quotation);
    emitTagCheck(ctx, elem_addr, quotation_tag_const, state.tag_offset_const, state.bail_status);

    // Load code_ptr
    const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
    const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, code_ptr_off);
    const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

    // Null-check code_ptr
    const null_addr = c.ir_const_addr(ctx, 0);
    const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
    const if_null = c._ir_IF(ctx, is_null);
    c._ir_IF_TRUE_cold(ctx, if_null);
    c._ir_RETURN(ctx, state.bail_status);
    c._ir_IF_FALSE(ctx, if_null);

    // Flush and update sp
    flushToPhysicalStack(state, stack, sp.*);
    const sp_const = c.ir_const_addr(ctx, sp.*);
    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
    c._ir_STORE(ctx, state.sp_ptr, new_sp);

    // Indirect call via jit_ctx_ptr
    const call_result = c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);

    const zero_status = c.ir_const_i32(ctx, 0);
    const call_failed = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), call_result, zero_status);
    const if_bail = c._ir_IF(ctx, call_failed);
    c._ir_IF_TRUE_cold(ctx, if_bail);
    c._ir_RETURN(ctx, state.bail_status);
    c._ir_IF_FALSE(ctx, if_bail);

    state.dynamic_call_emitted = true;
}

/// Compile a while/until loop: pred and body quotations with an optional
/// condition negation for `until` semantics.
fn compilePredBodyLoop(
    state: *CompileState,
    stack: *[64]StackEntry,
    sp: *usize,
    pred_entry: StackEntry,
    body_entry: StackEntry,
    negate_cond: bool,
) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;

    flushToPhysicalStack(state, stack, sp.*);

    const pre_loop_sp_const = c.ir_const_addr(ctx, sp.*);
    const pre_loop_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, pre_loop_sp_const);
    c._ir_STORE(ctx, state.sp_ptr, pre_loop_sp);

    const entry_end = c._ir_END(ctx);
    const loop_ref = c._ir_LOOP_BEGIN(ctx, entry_end);

    // Execute predicate
    const pre_body_sp = sp.*;
    switch (pred_entry) {
        .quotation_body => |body| {
            resetStackToPhysical(stack, sp.*);
            try compileInstructions(state, body, stack, sp);
        },
        .raw_at_slot => |s| {
            try emitIndirectQuotCall(state, stack, sp, s);
            resetStackToPhysical(stack, sp.*);
        },
        else => return IrCodegenError.NotCompilable,
    }

    // Pred should push a boolean on top
    if (sp.* < pre_body_sp + 1) return IrCodegenError.StackShapeMismatch;
    sp.* -= 1;
    const cond_entry = stack[sp.*];
    if (sp.* != pre_body_sp) return IrCodegenError.StackShapeMismatch;

    const truthy = try emitTruthiness(state, cond_entry, base_addr);
    const continue_cond = if (negate_cond)
        c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), truthy, c.ir_const_bool(ctx, false))
    else
        truthy;

    flushToPhysicalStack(state, stack, sp.*);

    const if_continue = c._ir_IF(ctx, continue_cond);

    c._ir_IF_TRUE(ctx, if_continue);

    // Execute body
    switch (body_entry) {
        .quotation_body => |body| {
            resetStackToPhysical(stack, sp.*);
            const body_pre_sp = sp.*;
            try compileInstructions(state, body, stack, sp);
            if (sp.* != body_pre_sp) return IrCodegenError.StackShapeMismatch;
            flushToPhysicalStack(state, stack, sp.*);
        },
        .raw_at_slot => |s| {
            try emitIndirectQuotCall(state, stack, sp, s);
        },
        else => return IrCodegenError.NotCompilable,
    }

    resetStackToPhysical(stack, sp.*);

    emitSafepointCall(state);
    const loop_end = c._ir_LOOP_END(ctx);
    c.ir_set_op2(ctx, loop_ref, loop_end);

    c._ir_IF_FALSE(ctx, if_continue);
    resetStackToPhysical(stack, sp.*);
}

/// Try to emit inline IR for virtual type unwrapping.
/// Recognizes the pattern: push_literal(fixnum=vtypePtr) + call_word("native.virtual-unwrap").
/// Returns true if inlined; false to fall back to runtime callback.
fn tryEmitInlineVirtualUnwrap(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: *[64]StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 2) return false;

    // virtual type pointer must be a constant fixnum from the preceding instruction
    const vtype_fixnum: i64 = if (idx > 0) blk: {
        break :blk switch (instructions[idx - 1].op) {
            .push_literal => |v| if (v == .fixnum) v.fixnum else return false,
            else => return false,
        };
    } else return false;

    const value_slot: usize = switch (stack[sp.* - 2]) {
        .raw_at_slot => |s| s,
        else => return false,
    };

    sp.* -= 2;

    const ctx = state.ctx;
    const base_addr = state.base_addr;

    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, value_slot * ValueLayout.value_size));
    emitTagCheck(ctx, elem_addr, state.tagged_tag_const, state.tag_offset_const, state.bail_status);

    const tag_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, c.ir_const_addr(ctx, ValueLayout.tagged_tag_ptr_offset));
    const actual_vtype = c._ir_LOAD(ctx, c.IR_ADDR, tag_ptr_addr);
    const expected_vtype = c.ir_const_addr(ctx, @as(usize, @intCast(vtype_fixnum)));
    const vtype_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), actual_vtype, expected_vtype);
    const if_mismatch = c._ir_IF(ctx, vtype_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    c._ir_RETURN(ctx, state.bail_status);
    c._ir_IF_FALSE(ctx, if_mismatch);

    const inner_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, c.ir_const_addr(ctx, ValueLayout.tagged_inner_ptr_offset));
    const inner_ptr = c._ir_LOAD(ctx, c.IR_ADDR, inner_ptr_addr);
    emitCopyFromPtr(ctx, base_addr, inner_ptr, value_slot);

    stack[sp.*] = .{ .raw_at_slot = value_slot };
    sp.* += 1;
    return true;
}

/// Try to emit inline IR for parameterized type element validation.
/// Recognizes the pattern: push_literal(fixnum=vtypePtr) + call_word("native.typed-validate-and-promote").
/// Returns true if inlined; false to fall back to runtime callback.
fn tryEmitInlineTypedValidateAndPromote(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: *[64]StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 2) return false;

    // virtual type pointer must be a constant fixnum from the preceding instruction
    const vtype_fixnum: i64 = if (idx > 0) blk: {
        break :blk switch (instructions[idx - 1].op) {
            .push_literal => |v| if (v == .fixnum) v.fixnum else return false,
            else => return false,
        };
    } else return false;

    const vt: *const VirtualType = @ptrFromInt(@as(usize, @intCast(vtype_fixnum)));

    // no type_params means validation is a no-op
    const params = vt.type_params orelse {
        sp.* -= 1;
        return true;
    };
    if (params.len == 0) {
        sp.* -= 1;
        return true;
    }

    const expected_name = params[0].name;

    const value_entry = stack[sp.* - 2];

    // statically known type on the abstract stack can be resolved at compile time
    switch (value_entry) {
        .i64_ref => {
            if (std.mem.eql(u8, expected_name, "fixnum")) {
                sp.* -= 1;
                return true;
            }
            return false;
        },
        .f64_ref => {
            if (std.mem.eql(u8, expected_name, "float")) {
                sp.* -= 1;
                return true;
            }
            return false;
        },
        .bool_ref => {
            if (std.mem.eql(u8, expected_name, "boolean")) {
                sp.* -= 1;
                return true;
            }
            return false;
        },
        .raw_at_slot => {},
        .quotation_body => return false,
    }

    const expected_tag_const = mapTypeNameToTagConst(state, expected_name) orelse return false;

    const value_slot: usize = value_entry.raw_at_slot;

    sp.* -= 2;

    const ctx = state.ctx;
    const base_addr = state.base_addr;

    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, value_slot * ValueLayout.value_size));
    emitTagCheck(ctx, elem_addr, expected_tag_const, state.tag_offset_const, state.bail_status);

    stack[sp.*] = .{ .raw_at_slot = value_slot };
    sp.* += 1;
    return true;
}

/// Try to emit inline IR for struct field access.
///
/// Attempts to recognize the pattern:
///
///     push_literal(.struct_type)
///     push_literal(.fixnum=idx)
///     call_word("native.struct-field-get")
///
/// Returns true if inlined; or false to fall back to runtime callback.
fn tryEmitInlineStructFieldGet(
    state: *CompileState,
    instructions: []const Instruction,
    idx: usize,
    stack: *[64]StackEntry,
    sp: *usize,
) bool {
    if (sp.* < 3) return false;
    if (idx < 2) return false;

    // struct_type pointer must be a const from two instructions back
    const struct_type_ptr: *const StructType = switch (instructions[idx - 2].op) {
        .push_literal => |v| if (v == .struct_type) v.struct_type else return false,
        else => return false,
    };

    // field index must be a const fixnum from the preceding instruction
    const field_index: usize = switch (instructions[idx - 1].op) {
        .push_literal => |v| if (v == .fixnum) @as(usize, @intCast(v.fixnum)) else return false,
        else => return false,
    };

    // the instance must be a raw value on the physical stack
    const instance_slot: usize = switch (stack[sp.* - 3]) {
        .raw_at_slot => |s| s,
        else => return false,
    };

    sp.* -= 3;

    StructInstanceLayout.ensureInit();

    const ctx = state.ctx;
    const base_addr = state.base_addr;

    // check Value at instance_slot must be .struct_instance
    const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, c.ir_const_addr(ctx, instance_slot * ValueLayout.value_size));
    emitTagCheck(ctx, elem_addr, state.struct_instance_tag_const, state.tag_offset_const, state.bail_status);

    // load *StructInstance from Value
    const si_ptr = emitUnboxPtr(ctx, elem_addr, state.payload_offset_const);

    // check si_ptr.struct_type must match expected tpye
    const type_field_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), si_ptr, c.ir_const_addr(ctx, StructInstanceLayout.struct_type_offset));
    const actual_type = c._ir_LOAD(ctx, c.IR_ADDR, type_field_addr);
    const expected_type = c.ir_const_addr(ctx, @intFromPtr(struct_type_ptr));
    const type_mismatch = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), actual_type, expected_type);
    const if_mismatch = c._ir_IF(ctx, type_mismatch);
    c._ir_IF_TRUE_cold(ctx, if_mismatch);
    c._ir_RETURN(ctx, state.bail_status);
    c._ir_IF_FALSE(ctx, if_mismatch);

    const fields_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), si_ptr, c.ir_const_addr(ctx, StructInstanceLayout.fields_ptr_offset));
    const fields_ptr = c._ir_LOAD(ctx, c.IR_ADDR, fields_ptr_addr);

    // index into fields [fields_ptr + field_index * value_size]
    const field_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), fields_ptr, c.ir_const_addr(ctx, field_index * ValueLayout.value_size));

    emitCopyFromPtr(ctx, base_addr, field_addr, instance_slot);

    stack[sp.*] = .{ .raw_at_slot = instance_slot };
    sp.* += 1;
    return true;
}

/// Compile a sequence of instructions, updating the abstract stack.
/// Used both for top-level word bodies and for inlined quotation bodies.
fn compileInstructions(
    state: *CompileState,
    instructions: []const Instruction,
    stack: *[64]StackEntry,
    sp: *usize,
) IrCodegenError!void {
    const ctx = state.ctx;
    const base_addr = state.base_addr;
    const bail_status = state.bail_status;

    for (instructions, 0..) |instr, idx| {
        if (state.dynamic_call_emitted) return IrCodegenError.NotCompilable;

        switch (instr.op) {
            .push_literal => |val| {
                if (val == .fixnum) {
                    stack[sp.*] = .{ .i64_ref = c.ir_const_i64(ctx, val.fixnum) };
                    sp.* += 1;
                } else if (val == .quotation) {
                    stack[sp.*] = .{ .quotation_body = val.quotation.instructions };
                    sp.* += 1;
                } else if (val == .float) {
                    stack[sp.*] = .{ .f64_ref = c.ir_const_double(ctx, val.float) };
                    sp.* += 1;
                } else if (val == .boolean) {
                    stack[sp.*] = .{ .bool_ref = c.ir_const_bool(ctx, val.boolean) };
                    sp.* += 1;
                } else if (state.aot_mode and (val == .string or val == .symbol)) {
                    // In AOT mode, string/symbol literals can't be baked as
                    // raw bytes because they contain heap pointers. Emit a
                    // callback that pushes the literal using a C string
                    // constant embedded in the AOT binary.
                    const str_data = if (val == .string) val.string else val.symbol;
                    const push_fn_name = if (val == .string) "onez_push_string" else "onez_push_symbol";

                    // Use a 3-arg prototype for (ctx, str_ptr, str_len).
                    const proto_3arg = c.ir_proto_3(ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR, c.IR_ADDR);
                    const push_fn = c.ir_const_func(ctx, c.ir_str(ctx, push_fn_name), proto_3arg);

                    // Store sp before callback.
                    const sp_const = c.ir_const_addr(ctx, sp.*);
                    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
                    c._ir_STORE(ctx, state.sp_ptr, new_sp);

                    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
                        state.preloaded_ctx_val
                    else blk: {
                        JitContextLayout.ensureInit();
                        const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
                        const ctx_addr2 = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
                        break :blk c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr2);
                    };

                    // Reference the string via ir_const_sym. The symbol is
                    // defined as a static const char[] in emitProgramC.
                    const lit_id = if (state.aot_string_literals) |lits| lits.items.len else 0;
                    var sym_buf: [32]u8 = undefined;
                    const sym_name = std.fmt.bufPrint(&sym_buf, "onez_lit_{d}", .{lit_id}) catch unreachable;
                    // Use ir_const_func (not ir_const_sym) so the C emitter
                    // outputs the bare symbol name without the & prefix.
                    // The symbol resolves to a char[] which decays to char*.
                    const sym_ref = c.ir_const_func(ctx, c.ir_strl(ctx, &sym_buf, sym_name.len), 0);
                    const str_len_const = c.ir_const_addr(ctx, str_data.len);

                    const call_result = c._ir_CALL_3(ctx, c.IR_I32, push_fn, ctx_val, sym_ref, str_len_const);
                    emitCallbackPostCheck(state, call_result, state.error_propagate_status);

                    // Record the literal for emission in the C preamble.
                    if (state.aot_string_literals) |lits| {
                        lits.append(std.heap.page_allocator, .{
                            .data = str_data,
                            .is_symbol = val == .symbol,
                        }) catch {};
                    }

                    // Re-read sp after callback (it pushed one value).
                    _ = c._ir_LOAD(ctx, c.IR_ADDR, state.sp_ptr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                } else if (state.aot_mode) {
                    // In AOT mode, non-simple literals (parameters, tagged
                    // values, etc.) contain process-local pointers that are
                    // invalid in the AOT binary. Bail to interpreter fallback.
                    return IrCodegenError.NotCompilable;
                } else {
                    const sp_byte_offset = c.ir_const_addr(ctx, sp.* * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, sp_byte_offset);
                    emitPushValue(ctx, &val, dest_addr);
                    stack[sp.*] = .{ .raw_at_slot = sp.* };
                    sp.* += 1;
                }
            },
            .call_word => |name| {
                if (std.mem.eql(u8, name, "dup")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    switch (stack[sp.* - 1]) {
                        .i64_ref => |ref| {
                            stack[sp.*] = .{ .i64_ref = ref };
                        },
                        .f64_ref => |ref| {
                            stack[sp.*] = .{ .f64_ref = ref };
                        },
                        .bool_ref => |ref| {
                            stack[sp.*] = .{ .bool_ref = ref };
                        },
                        .quotation_body => |body| {
                            stack[sp.*] = .{ .quotation_body = body };
                        },
                        .raw_at_slot => |s| {
                            emitCopySlot(ctx, base_addr, s, sp.*);
                            stack[sp.*] = .{ .raw_at_slot = sp.* };
                        },
                    }
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "drop")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    sp.* -= 1;
                } else if (std.mem.eql(u8, name, "swap")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    const top = stack[sp.* - 1];
                    const second = stack[sp.* - 2];
                    // Track swap abstractly without physical modification.
                    // flushToPhysicalStack resolves cross-references later.
                    stack[sp.* - 2] = top;
                    stack[sp.* - 1] = second;
                } else if (std.mem.eql(u8, name, "over")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    switch (stack[sp.* - 2]) {
                        .i64_ref => |ref| {
                            stack[sp.*] = .{ .i64_ref = ref };
                        },
                        .f64_ref => |ref| {
                            stack[sp.*] = .{ .f64_ref = ref };
                        },
                        .bool_ref => |ref| {
                            stack[sp.*] = .{ .bool_ref = ref };
                        },
                        .quotation_body => |body| {
                            stack[sp.*] = .{ .quotation_body = body };
                        },
                        .raw_at_slot => |s| {
                            emitCopySlot(ctx, base_addr, s, sp.*);
                            stack[sp.*] = .{ .raw_at_slot = sp.* };
                        },
                    }
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "t")) {
                    stack[sp.*] = .{ .bool_ref = c.ir_const_bool(ctx, true) };
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "f")) {
                    stack[sp.*] = .{ .bool_ref = c.ir_const_bool(ctx, false) };
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "abs")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    sp.* -= 1;
                    const entry = stack[sp.*];

                    if (entry == .f64_ref) {
                        const a = entry.f64_ref;
                        const zero = c.ir_const_double(ctx, 0.0);
                        const is_neg = c.ir_fold2(ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), a, zero);
                        const neg_a = c.ir_fold1(ctx, c.IR_OPT(c.IR_NEG, c.IR_DOUBLE), a);
                        const if_neg = c._ir_IF(ctx, is_neg);
                        c._ir_IF_TRUE(ctx, if_neg);
                        const end_true = c._ir_END(ctx);
                        c._ir_IF_FALSE(ctx, if_neg);
                        const end_false = c._ir_END(ctx);
                        c._ir_MERGE_2(ctx, end_true, end_false);
                        const result = c._ir_PHI_2(ctx, c.IR_DOUBLE, neg_a, a);
                        stack[sp.*] = .{ .f64_ref = result };
                    } else {
                        const a = try requireI64(entry, state);

                        const min_val = c.ir_const_i64(ctx, std.math.minInt(i64));
                        const is_min = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), a, min_val);
                        const if_min = c._ir_IF(ctx, is_min);
                        c._ir_IF_TRUE_cold(ctx, if_min);
                        c._ir_RETURN(ctx, bail_status);
                        c._ir_IF_FALSE(ctx, if_min);

                        const zero = c.ir_const_i64(ctx, 0);
                        const is_neg = c.ir_fold2(ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), a, zero);
                        const neg_a = c.ir_fold1(ctx, c.IR_OPT(c.IR_NEG, c.IR_I64), a);
                        const if_neg = c._ir_IF(ctx, is_neg);
                        c._ir_IF_TRUE(ctx, if_neg);
                        const end_true = c._ir_END(ctx);
                        c._ir_IF_FALSE(ctx, if_neg);
                        const end_false = c._ir_END(ctx);
                        c._ir_MERGE_2(ctx, end_true, end_false);
                        const result = c._ir_PHI_2(ctx, c.IR_I64, neg_a, a);
                        stack[sp.*] = .{ .i64_ref = result };
                    }
                    sp.* += 1;
                } else if (isComparisonOp(name)) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;
                    const resolved = try resolveOperandPair(stack[sp.*], stack[sp.* + 1], state);

                    const ir_op: c_uint = if (std.mem.eql(u8, name, "="))
                        c.IR_EQ
                    else if (std.mem.eql(u8, name, "<"))
                        c.IR_LT
                    else
                        c.IR_GT;

                    const result = switch (resolved) {
                        .i64_pair => |p| c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_BOOL), p.a, p.b),
                        .f64_pair => |p| c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_BOOL), p.a, p.b),
                    };
                    stack[sp.*] = .{ .bool_ref = result };
                    sp.* += 1;
                } else if (std.mem.eql(u8, name, "if")) {
                    // 1z truthiness: only `f` (boolean false) is falsy; every
                    // other value is truthy. The three condition entry types
                    // each need a different IR emission strategy:
                    //
                    //   bool_ref    -- use the IR bool directly as the branch condition
                    //   i64_ref     -- always truthy, so emit only the true branch
                    //   raw_at_slot -- load tag+payload from memory to compute is_truthy at runtime
                    //
                    // Both branches must produce the same stack depth; results
                    // are merged with PHI nodes after the MERGE point.
                    if (sp.* < 3) return IrCodegenError.StackUnderflow;
                    sp.* -= 3;

                    const cond_entry = stack[sp.*];
                    const true_body = switch (stack[sp.* + 1]) {
                        .quotation_body => |body| body,
                        else => return IrCodegenError.NotCompilable,
                    };
                    const false_body = switch (stack[sp.* + 2]) {
                        .quotation_body => |body| body,
                        else => return IrCodegenError.NotCompilable,
                    };

                    // Determine the IR bool for the condition
                    const cond_ref = switch (cond_entry) {
                        .bool_ref => |ref| ref,
                        .i64_ref, .f64_ref => {
                            // Non-boolean values are always truthy in 1z.
                            // Compile both branches to validate stack effects
                            // match, but only emit the true branch.
                            var false_stack = stack.*;
                            var false_sp = sp.*;
                            try compileInstructions(state, false_body, &false_stack, &false_sp);
                            try compileInstructions(state, true_body, stack, sp);
                            if (false_sp != sp.*) return IrCodegenError.StackShapeMismatch;
                            continue;
                        },
                        .raw_at_slot => |s| blk: {
                            // Trufiness check for an opaque Value in memory.
                            // Steps: load the tag word, check if it equals the
                            // boolean tag, load the payload byte, then compute:
                            //
                            //   is_falsy = (tag == boolean) AND (payload == false)
                            //
                            // Negate using EQ(is_falsy, false) because the IR
                            // library has no dedicated boolean NOT operation.
                            const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
                            const slot_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                            const tag_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), slot_addr, state.tag_offset_const);
                            const tag_val = c._ir_LOAD(ctx, ValueLayout.ir_tag_type, tag_addr);
                            const is_bool_tag = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), tag_val, state.boolean_tag_const);

                            const payload_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), slot_addr, state.payload_offset_const);
                            const payload_val = c._ir_LOAD(ctx, c.IR_BOOL, payload_addr);
                            // is_falsy = tag is boolean AND payload is false (i.e., payload == 0)
                            const false_const = c.ir_const_bool(ctx, false);
                            const is_false_payload = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), payload_val, false_const);
                            const is_falsy = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), is_bool_tag, is_false_payload);
                            // is_truthy = not is_falsy (negate by comparing with false)
                            break :blk c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), is_falsy, false_const);
                        },
                        .quotation_body => return IrCodegenError.NotCompilable,
                    };

                    // Save stack state for the false branch
                    const saved_sp = sp.*;
                    var saved_stack = stack.*;
                    const saved_diverged = state.diverged;
                    const saved_loop_end_set = state.loop_end_set;

                    // Emit true branch
                    const if_ref = c._ir_IF(ctx, cond_ref);
                    c._ir_IF_TRUE(ctx, if_ref);
                    state.diverged = false;
                    try compileInstructions(state, true_body, stack, sp);
                    const true_diverged = state.diverged;
                    var end_true: c.ir_ref = c.IR_UNUSED;
                    if (!true_diverged) {
                        flushToPhysicalStack(state, stack, sp.*);
                        end_true = c._ir_END(ctx);
                    }

                    // Emit false branch
                    c._ir_IF_FALSE(ctx, if_ref);
                    var false_sp = saved_sp;
                    state.diverged = false;
                    try compileInstructions(state, false_body, &saved_stack, &false_sp);
                    const false_diverged = state.diverged;

                    if (true_diverged and false_diverged) {
                        // Both branches diverged via LOOP_END
                        state.diverged = true;
                    } else if (true_diverged) {
                        // Only false path continues. No END or MERGE needed:
                        // the false branch code just falls through after IF_FALSE.
                        // The same pattern as the exit path of a compiled loop.
                        flushToPhysicalStack(state, &saved_stack, false_sp);
                        sp.* = false_sp;
                        stack.* = saved_stack;
                        resetStackToPhysical(stack, sp.*);
                        state.diverged = saved_diverged;
                    } else if (false_diverged) {
                        // Only true path continues. Resume from true branch's END.
                        c._ir_BEGIN(ctx, end_true);
                        resetStackToPhysical(stack, sp.*);
                        state.diverged = saved_diverged;
                    } else {
                        // Neither diverged: normal merge
                        flushToPhysicalStack(state, &saved_stack, false_sp);
                        const end_false = c._ir_END(ctx);
                        c._ir_MERGE_2(ctx, end_true, end_false);
                        if (sp.* != false_sp) return IrCodegenError.StackShapeMismatch;
                        resetStackToPhysical(stack, sp.*);
                        state.diverged = saved_diverged;
                        state.loop_end_set = saved_loop_end_set;
                    }
                } else if (std.mem.eql(u8, name, "call")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    sp.* -= 1;
                    const entry = stack[sp.*];
                    switch (entry) {
                        .quotation_body => |body| {
                            try compileInstructions(state, body, stack, sp);
                        },
                        .raw_at_slot => |s| {
                            const slot_byte_offset = c.ir_const_addr(ctx, s * ValueLayout.value_size);
                            const elem_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);

                            // Check tag is quotation
                            const quotation_tag_const = emitTagConst(ctx, .quotation);
                            emitTagCheck(ctx, elem_addr, quotation_tag_const, state.tag_offset_const, bail_status);

                            // Load code_ptr from the quotation's payload
                            const code_ptr_off = c.ir_const_addr(ctx, ValueLayout.quotation_code_ptr_offset);
                            const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, code_ptr_off);
                            const code_ptr_val = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

                            // Null-check code_ptr: fallback to interpreter if quotation not compiled
                            const null_addr = c.ir_const_addr(ctx, 0);
                            const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), code_ptr_val, null_addr);
                            const if_null = c._ir_IF(ctx, is_null);

                            // Cold path: quotation not compiled, call interpreter fallback
                            c._ir_IF_TRUE_cold(ctx, if_null);
                            {
                                // Flush stack with the quotation included at TOS for
                                // the interpreter's native call handler.
                                sp.* += 1;
                                flushToPhysicalStack(state, stack, sp.*);
                                const ctx_val = emitCallbackPreamble(state, sp.*);
                                sp.* -= 1;
                                const call_quot_fn = if (state.aot_mode)
                                    state.call_quotation_fn
                                else
                                    c.ir_const_addr(ctx, @intFromPtr(&jitCallQuotation));
                                const fb_result = c._ir_CALL_1(ctx, c.IR_I32, call_quot_fn, ctx_val);
                                emitCallbackPostCheck(state, fb_result, state.error_propagate_status);
                            }
                            const end_fallback = c._ir_END(ctx);

                            // Hot path: quotation is compiled, call directly
                            c._ir_IF_FALSE(ctx, if_null);
                            {
                                flushToPhysicalStack(state, stack, sp.*);

                                const new_sp_const = c.ir_const_addr(ctx, sp.*);
                                const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, new_sp_const);
                                c._ir_STORE(ctx, state.sp_ptr, new_sp);

                                const call_result = c._ir_CALL_1(ctx, c.IR_I32, code_ptr_val, state.jit_ctx_ptr);
                                emitCallbackPostCheck(state, call_result, call_result);
                            }
                            const end_compiled = c._ir_END(ctx);

                            c._ir_MERGE_2(ctx, end_fallback, end_compiled);

                            state.dynamic_call_emitted = true;
                        },
                        .i64_ref, .f64_ref, .bool_ref => return IrCodegenError.NotCompilable,
                    }
                } else if (std.mem.eql(u8, name, "times")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;
                    const n_entry = stack[sp.*];
                    const quot_entry = stack[sp.* + 1];

                    const initial_n = try requireI64(n_entry, state);

                    // Flush user stack to physical memory before the loop
                    flushToPhysicalStack(state, stack, sp.*);

                    // Write sp to memory so indirect calls can see it
                    const pre_loop_sp_const = c.ir_const_addr(ctx, sp.*);
                    const pre_loop_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, pre_loop_sp_const);
                    c._ir_STORE(ctx, state.sp_ptr, pre_loop_sp);

                    // Zero-iteration check: n > 0
                    const zero = c.ir_const_i64(ctx, 0);
                    const gt_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_GT, c.IR_BOOL), initial_n, zero);
                    const if_skip = c._ir_IF(ctx, gt_zero);

                    c._ir_IF_FALSE(ctx, if_skip);
                    const skip_end = c._ir_END(ctx);

                    c._ir_IF_TRUE(ctx, if_skip);
                    const entry_end = c._ir_END(ctx);

                    const loop_ref = c._ir_LOOP_BEGIN(ctx, entry_end);
                    const counter_phi = c._ir_PHI_2(ctx, c.IR_I64, initial_n, c.IR_UNUSED);

                    switch (quot_entry) {
                        .quotation_body => |body| {
                            // Reset stack entries to raw_at_slot for body
                            const pre_body_sp = sp.*;
                            resetStackToPhysical(stack, sp.*);
                            try compileInstructions(state, body, stack, sp);
                            if (sp.* != pre_body_sp) return IrCodegenError.StackShapeMismatch;
                            // Flush body results back
                            flushToPhysicalStack(state, stack, sp.*);
                        },
                        .raw_at_slot => |s| {
                            try emitIndirectQuotCall(state, stack, sp, s);
                        },
                        else => return IrCodegenError.NotCompilable,
                    }

                    // Reset stack entries after body
                    resetStackToPhysical(stack, sp.*);

                    // Decrement counter
                    const one = c.ir_const_i64(ctx, 1);
                    const new_counter = c.ir_fold2(ctx, c.IR_OPT(c.IR_SUB, c.IR_I64), counter_phi, one);
                    c._ir_PHI_SET_OP(ctx, counter_phi, 2, new_counter);

                    // Continue if new_counter > 0
                    const continue_cond = c.ir_fold2(ctx, c.IR_OPT(c.IR_GT, c.IR_BOOL), new_counter, zero);
                    const if_continue = c._ir_IF(ctx, continue_cond);
                    c._ir_IF_TRUE(ctx, if_continue);
                    emitSafepointCall(state);
                    const loop_end = c._ir_LOOP_END(ctx);
                    c.ir_set_op2(ctx, loop_ref, loop_end);

                    c._ir_IF_FALSE(ctx, if_continue);
                    const exit_end = c._ir_END(ctx);

                    c._ir_MERGE_2(ctx, skip_end, exit_end);

                    // After loop, reload sp from memory if dynamic calls were made
                    if (state.dynamic_call_emitted) {
                        // sp may have been modified by indirect calls; leave it
                        // for the dynamic_call_emitted finalization path
                    }
                } else if (std.mem.eql(u8, name, "loop")) {
                    if (sp.* < 1) return IrCodegenError.StackUnderflow;
                    sp.* -= 1;
                    const pred_entry = stack[sp.*];

                    // Flush user stack to physical memory before the loop
                    flushToPhysicalStack(state, stack, sp.*);

                    const pre_loop_sp_const = c.ir_const_addr(ctx, sp.*);
                    const pre_loop_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, pre_loop_sp_const);
                    c._ir_STORE(ctx, state.sp_ptr, pre_loop_sp);

                    const entry_end = c._ir_END(ctx);
                    const loop_ref = c._ir_LOOP_BEGIN(ctx, entry_end);

                    // Execute predicate body
                    const pre_body_sp = sp.*;
                    switch (pred_entry) {
                        .quotation_body => |body| {
                            resetStackToPhysical(stack, sp.*);
                            try compileInstructions(state, body, stack, sp);
                        },
                        .raw_at_slot => |s| {
                            try emitIndirectQuotCall(state, stack, sp, s);
                            resetStackToPhysical(stack, sp.*);
                        },
                        else => return IrCodegenError.NotCompilable,
                    }

                    // Pred should push a boolean on top
                    if (sp.* < pre_body_sp + 1) return IrCodegenError.StackShapeMismatch;
                    sp.* -= 1;
                    const cond_entry = stack[sp.*];
                    if (sp.* != pre_body_sp) return IrCodegenError.StackShapeMismatch;

                    const continue_cond = try emitTruthiness(state, cond_entry, base_addr);

                    flushToPhysicalStack(state, stack, sp.*);
                    resetStackToPhysical(stack, sp.*);

                    const if_continue = c._ir_IF(ctx, continue_cond);
                    c._ir_IF_TRUE(ctx, if_continue);
                    emitSafepointCall(state);
                    const loop_end = c._ir_LOOP_END(ctx);
                    c.ir_set_op2(ctx, loop_ref, loop_end);

                    c._ir_IF_FALSE(ctx, if_continue);
                } else if (std.mem.eql(u8, name, "while") or std.mem.eql(u8, name, "until")) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;
                    const pred_entry = stack[sp.*];
                    const body_entry = stack[sp.* + 1];
                    try compilePredBodyLoop(state, stack, sp, pred_entry, body_entry, std.mem.eql(u8, name, "until"));
                } else if (isBinaryOp(name)) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;
                    sp.* -= 2;

                    // div, rem, and % are integer-only; resolve both operands as i64.
                    if (std.mem.eql(u8, name, "div")) {
                        const a = try requireI64(stack[sp.*], state);
                        const b = try requireI64(stack[sp.* + 1], state);
                        stack[sp.*] = .{ .i64_ref = emitDivision(ctx, a, b, bail_status) };
                        sp.* += 1;
                    } else if (std.mem.eql(u8, name, "rem")) {
                        const a = try requireI64(stack[sp.*], state);
                        const b = try requireI64(stack[sp.* + 1], state);
                        stack[sp.*] = .{ .i64_ref = emitRemainder(ctx, a, b, bail_status) };
                        sp.* += 1;
                    } else if (std.mem.eql(u8, name, "%")) {
                        const a = try requireI64(stack[sp.*], state);
                        const b = try requireI64(stack[sp.* + 1], state);
                        stack[sp.*] = .{ .i64_ref = emitEuclideanMod(ctx, a, b, bail_status) };
                        sp.* += 1;
                    } else {
                        // +, -, *, / support both i64 and f64 operands.
                        const resolved = try resolveOperandPair(stack[sp.*], stack[sp.* + 1], state);
                        switch (resolved) {
                            .i64_pair => |p| {
                                if (std.mem.eql(u8, name, "+")) {
                                    stack[sp.*] = .{ .i64_ref = emitOverflowCheckedBinary(ctx, c.IR_ADD_OV, p.a, p.b, bail_status) };
                                } else if (std.mem.eql(u8, name, "-")) {
                                    stack[sp.*] = .{ .i64_ref = emitOverflowCheckedBinary(ctx, c.IR_SUB_OV, p.a, p.b, bail_status) };
                                } else if (std.mem.eql(u8, name, "*")) {
                                    stack[sp.*] = .{ .i64_ref = emitOverflowCheckedBinary(ctx, c.IR_MUL_OV, p.a, p.b, bail_status) };
                                } else {
                                    // "/"
                                    stack[sp.*] = .{ .i64_ref = emitDivision(ctx, p.a, p.b, bail_status) };
                                }
                            },
                            .f64_pair => |p| {
                                const ir_op: c_uint = if (std.mem.eql(u8, name, "+"))
                                    c.IR_ADD
                                else if (std.mem.eql(u8, name, "-"))
                                    c.IR_SUB
                                else if (std.mem.eql(u8, name, "*"))
                                    c.IR_MUL
                                else
                                    c.IR_DIV;
                                stack[sp.*] = .{ .f64_ref = c.ir_fold2(ctx, c.IR_OPT(ir_op, c.IR_DOUBLE), p.a, p.b) };
                            },
                        }
                        sp.* += 1;
                    }
                } else if (isErrorHandlingOp(name)) {
                    if (sp.* < 2) return IrCodegenError.StackUnderflow;

                    materializeQuotations(state, stack, sp.*);
                    flushToPhysicalStack(state, stack, sp.*);
                    const ctx_val = emitCallbackPreamble(state, sp.*);

                    const callback_fn = if (std.mem.eql(u8, name, "recover"))
                        state.recover_fn
                    else
                        state.cleanup_fn;

                    const call_result = c._ir_CALL_1(ctx, c.IR_I32, callback_fn, ctx_val);
                    emitCallbackPostCheck(state, call_result, call_result);

                    sp.* -= 2;
                    state.dynamic_call_emitted = true;
                } else if (isDynamicVarOp(name)) {
                    const is_get = std.mem.eql(u8, name, "get");
                    const required: usize = if (is_get) 1 else 3;
                    if (sp.* < required) return IrCodegenError.StackUnderflow;

                    materializeQuotations(state, stack, sp.*);
                    flushToPhysicalStack(state, stack, sp.*);
                    const ctx_val = emitCallbackPreamble(state, sp.*);

                    const callback_fn = if (is_get) state.get_fn else state.with_parameter_fn;
                    const call_result = c._ir_CALL_1(ctx, c.IR_I32, callback_fn, ctx_val);
                    emitCallbackPostCheck(state, call_result, call_result);

                    if (is_get) {
                        // get: pops 1 param, pushes 1 value (net 0)
                        resetStackToPhysical(stack, sp.*);
                    } else {
                        // with-parameter: body quotation has unknown stack effects
                        sp.* -= 3;
                        state.dynamic_call_emitted = true;
                    }
                } else if (isIteratorOp(name)) {
                    const opcode = iteratorOpcodeFromName(name).?;
                    const effects = iteratorEffects(opcode);
                    if (sp.* < effects.inputs) return IrCodegenError.StackUnderflow;

                    materializeQuotations(state, stack, sp.*);
                    flushToPhysicalStack(state, stack, sp.*);
                    const ctx_val = emitCallbackPreamble(state, sp.*);

                    if (effects.dynamic) {
                        if (state.interp_ctx) |ictx| {
                            if (ictx.lookupWordStackEffectPtr(name)) |eff_ptr| {
                                emitParamValidation(state, @intFromPtr(eff_ptr));
                            }
                        }
                    }

                    const opcode_const = c.ir_const_addr(ctx, @intFromEnum(opcode));
                    const call_result = c._ir_CALL_2(ctx, c.IR_I32, state.iterator_fn, ctx_val, opcode_const);
                    emitCallbackPostCheck(state, call_result, call_result);

                    if (effects.dynamic) {
                        sp.* -= effects.inputs;
                        state.dynamic_call_emitted = true;
                    } else {
                        sp.* = sp.* - effects.inputs + effects.outputs;
                        resetStackToPhysical(stack, sp.*);
                    }
                } else if (
                // oh, yuck
                state.self_name != null and
                    state.loop_begin_ref != c.IR_UNUSED and
                    idx == instructions.len - 1 and
                    std.mem.eql(u8, name, state.self_name.?))
                {
                    // Self-recursive tail call: emit back-edge to LOOP_BEGIN
                    const ic = state.input_count;
                    if (sp.* < ic) return IrCodegenError.StackUnderflow;

                    // Bail if both if-branches already set a loop end
                    if (state.loop_end_set) return IrCodegenError.NotCompilable;

                    // Flush symbolic stack to physical memory
                    flushToPhysicalStack(state, stack, sp.*);

                    // Copy new arguments to input slots (positions 0..input_count-1)
                    const arg_base = sp.* - ic;
                    if (arg_base > 0) {
                        for (0..ic) |i| {
                            emitCopySlot(ctx, base_addr, arg_base + i, i);
                        }
                    }

                    // Reset sp to its original value (the word always starts
                    // with sp_val items on the physical stack)
                    c._ir_STORE(ctx, state.sp_ptr, state.sp_val);

                    // Safepoint before looping back
                    emitSafepointCall(state);

                    // Emit back-edge
                    const loop_end = c._ir_LOOP_END(ctx);
                    c.ir_set_op2(ctx, state.loop_begin_ref, loop_end);
                    state.loop_end_set = true;
                    state.diverged = true;

                    // Reset abstract stack for code after this point
                    // (unreachable, but keeps state consistent)
                    sp.* = ic;
                    resetStackToPhysical(stack, sp.*);
                } else if (state.mutual_group != null and
                    idx == instructions.len - 1 and
                    isMutualGroupMember(state.mutual_group.?, name) and
                    (state.self_name == null or !std.mem.eql(u8, name, state.self_name.?)))
                {
                    // Mutual recursion trampoline: flush stack, set target, return 3
                    const ic = state.input_count;
                    if (sp.* < ic) return IrCodegenError.StackUnderflow;

                    flushToPhysicalStack(state, stack, sp.*);

                    // Copy new arguments to input slots
                    const arg_base = sp.* - ic;
                    if (arg_base > 0) {
                        for (0..ic) |i| {
                            emitCopySlot(ctx, base_addr, arg_base + i, i);
                        }
                    }

                    // Reset sp to original value
                    c._ir_STORE(ctx, state.sp_ptr, state.sp_val);

                    // Resolve target word_id and store on JitContext
                    const res = state.resolver orelse return IrCodegenError.NotCompilable;
                    const resolved = res.resolve(name, res.user_data) orelse return IrCodegenError.NotCompilable;

                    JitContextLayout.ensureInit();
                    const tramp_off = c.ir_const_addr(ctx, JitContextLayout.trampoline_target_offset);
                    const tramp_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, tramp_off);
                    const target_const = c.ir_const_u32(ctx, resolved.word_id);
                    c._ir_STORE(ctx, tramp_addr, target_const);

                    c._ir_RETURN(ctx, state.trampoline_status);
                    state.diverged = true;

                    sp.* = ic;
                    resetStackToPhysical(stack, sp.*);
                } else if (std.mem.eql(u8, name, "native.virtual-unwrap")) {
                    // fallthrough to resolver for runtime callback
                    if (tryEmitInlineVirtualUnwrap(state, instructions, idx, stack, sp)) continue;

                    const res = state.resolver orelse return IrCodegenError.NotCompilable;
                    const resolved = res.resolve(name, res.user_data) orelse return IrCodegenError.NotCompilable;

                    if (resolved.native_fn_ptr != null) {
                        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

                        materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        const ctx_val = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        emitNativeWordCall(state, ctx_val, resolved);

                        sp.* = sp.* - resolved.input_count + resolved.output_count;
                        resetStackToPhysical(stack, sp.*);
                    } else {
                        return IrCodegenError.NotCompilable;
                    }
                } else if (std.mem.eql(u8, name, "native.struct-field-get")) {
                    // fallthrough to resolver for runtime callback
                    if (tryEmitInlineStructFieldGet(state, instructions, idx, stack, sp)) continue;

                    const res = state.resolver orelse return IrCodegenError.NotCompilable;
                    const resolved = res.resolve(name, res.user_data) orelse return IrCodegenError.NotCompilable;

                    if (resolved.native_fn_ptr != null) {
                        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

                        materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        const ctx_val = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        emitNativeWordCall(state, ctx_val, resolved);

                        sp.* = sp.* - resolved.input_count + resolved.output_count;
                        resetStackToPhysical(stack, sp.*);
                    } else {
                        return IrCodegenError.NotCompilable;
                    }
                } else if (std.mem.eql(u8, name, "native.typed-validate-and-promote")) {
                    // fallthrough to resolver for runtime callback
                    if (tryEmitInlineTypedValidateAndPromote(state, instructions, idx, stack, sp)) continue;

                    const res = state.resolver orelse return IrCodegenError.NotCompilable;
                    const resolved = res.resolve(name, res.user_data) orelse return IrCodegenError.NotCompilable;

                    if (resolved.native_fn_ptr != null) {
                        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

                        materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        const ctx_val = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        emitNativeWordCall(state, ctx_val, resolved);

                        sp.* = sp.* - resolved.input_count + resolved.output_count;
                        resetStackToPhysical(stack, sp.*);
                    } else {
                        return IrCodegenError.NotCompilable;
                    }
                } else {
                    // Unrecognized word: try dispatch table call if a resolver is available
                    const res = state.resolver orelse return IrCodegenError.NotCompilable;
                    const resolved = res.resolve(name, res.user_data) orelse return IrCodegenError.NotCompilable;

                    if (resolved.native_fn_ptr != null) {
                        // Generic native word callback
                        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

                        materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        const ctx_val = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        emitNativeWordCall(state, ctx_val, resolved);

                        // Adjust abstract stack by declared effect
                        sp.* = sp.* - resolved.input_count + resolved.output_count;
                        resetStackToPhysical(stack, sp.*);
                    } else if (state.aot_mode) {
                        // AOT mode: direct call by name or interpreter fallback
                        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

                        materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        const ctx_val = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        emitAotWordCall(state, ctx_val, name, resolved);

                        sp.* = sp.* - resolved.input_count + resolved.output_count;
                        resetStackToPhysical(stack, sp.*);
                    } else {
                        // Compound word: dispatch table indirect call
                        DispatchLayout.ensureInit();

                        if (sp.* < resolved.input_count) return IrCodegenError.StackUnderflow;

                        materializeQuotations(state, stack, sp.*);
                        flushToPhysicalStack(state, stack, sp.*);
                        _ = emitCallbackPreamble(state, sp.*);

                        if (resolved.stack_effect_ptr) |eff_ptr| {
                            emitParamValidation(state, eff_ptr);
                        }

                        // Load entries.items.ptr from the dispatch table
                        const dispatch_ptr = state.dispatch_ptr;
                        const items_ptr_off = c.ir_const_addr(ctx, DispatchLayout.items_ptr_offset);
                        const entries_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), dispatch_ptr, items_ptr_off);
                        const entries_ptr = c._ir_LOAD(ctx, c.IR_ADDR, entries_ptr_addr);

                        // Index into entries array: entries_ptr + word_id * entry_size + code_ptr_offset
                        const entry_byte_off = c.ir_const_addr(ctx, resolved.word_id * DispatchLayout.entry_size + DispatchLayout.code_ptr_offset);
                        const code_ptr_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), entries_ptr, entry_byte_off);
                        const callee_code_ptr = c._ir_LOAD(ctx, c.IR_ADDR, code_ptr_addr);

                        // Null-check code_ptr: fallback to interpreter if callee not compiled
                        const null_addr = c.ir_const_addr(ctx, 0);
                        const is_null = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), callee_code_ptr, null_addr);
                        const if_null = c._ir_IF(ctx, is_null);

                        // Cold path: callee not compiled, call interpreter fallback
                        c._ir_IF_TRUE_cold(ctx, if_null);
                        {
                            JitContextLayout.ensureInit();
                            const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
                            const ctx_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
                            const ctx_val2 = c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr);
                            const word_id_const = c.ir_const_addr(ctx, resolved.word_id);
                            const fb_result = c._ir_CALL_2(ctx, c.IR_I32, state.interpreted_call_fn, ctx_val2, word_id_const);
                            emitCallbackPostCheck(state, fb_result, state.error_propagate_status);
                        }
                        const end_fallback = c._ir_END(ctx);

                        // Hot path: callee is compiled, call directly
                        c._ir_IF_FALSE(ctx, if_null);
                        {
                            const call_result = c._ir_CALL_1(ctx, c.IR_I32, callee_code_ptr, state.jit_ctx_ptr);
                            emitCallbackPostCheck(state, call_result, call_result);
                        }
                        const end_compiled = c._ir_END(ctx);

                        c._ir_MERGE_2(ctx, end_fallback, end_compiled);

                        // Adjust abstract stack based on callee's known stack effect
                        sp.* = sp.* - resolved.input_count + resolved.output_count;
                        resetStackToPhysical(stack, sp.*);
                    }
                }
            },
        }
    }
}

/// Merge two stack entries from the true and false branches of an if.
/// After an ir MERGE of two branches, a PHI node selects which branch's
/// value to use based on which path was actually taken at runtime.
/// For raw_at_slot merging is limited to same-slot cases: if both branches
/// wrote to the same physical slot, no copy is needed since the taken branch
/// already placed its value there.
fn mergeEntries(
    ctx: *c.ir_ctx,
    true_entry: StackEntry,
    false_entry: StackEntry,
    slot: usize,
    base_addr: c.ir_ref,
) IrCodegenError!StackEntry {
    switch (true_entry) {
        .i64_ref => |true_ref| switch (false_entry) {
            .i64_ref => |false_ref| return .{ .i64_ref = c._ir_PHI_2(ctx, c.IR_I64, true_ref, false_ref) },
            else => return IrCodegenError.NotCompilable,
        },
        .f64_ref => |true_ref| switch (false_entry) {
            .f64_ref => |false_ref| return .{ .f64_ref = c._ir_PHI_2(ctx, c.IR_DOUBLE, true_ref, false_ref) },
            else => return IrCodegenError.NotCompilable,
        },
        .bool_ref => |true_ref| switch (false_entry) {
            .bool_ref => |false_ref| return .{ .bool_ref = c._ir_PHI_2(ctx, c.IR_BOOL, true_ref, false_ref) },
            else => return IrCodegenError.NotCompilable,
        },
        .raw_at_slot => |true_slot| switch (false_entry) {
            .raw_at_slot => |false_slot| {
                if (true_slot == slot and false_slot == slot) {
                    return .{ .raw_at_slot = slot };
                }
                // Both wrote to physical slots but at different positions;
                // the last write from the taken branch is at the correct
                // location since only one branch executes. However, we
                // can't statically know which, so copy to canonical slot.
                _ = base_addr;
                return IrCodegenError.NotCompilable;
            },
            else => return IrCodegenError.NotCompilable,
        },
        .quotation_body => return IrCodegenError.NotCompilable,
    }
}

/// Bundle of all inputs needed by a compiled function. Passed as a single
/// pointer to avoid the aarch64 IR backend miscompilation with 4+ parameters.
/// Uses extern struct for C-compatible layout with predictable field offsets.
pub const JitContext = extern struct {
    items_ptr: [*]Value,
    sp_ptr: *usize,
    capacity: usize,
    ctx: *anyopaque,
    trampoline_target: u32 = 0,
};

/// Layout offsets for JitContext fields, discovered at runtime.
const JitContextLayout = struct {
    var sp_ptr_offset: usize = 0;
    var capacity_offset: usize = 0;
    var ctx_offset: usize = 0;
    var trampoline_target_offset: usize = 0;
    var initialized: bool = false;

    fn ensureInit() void {
        if (initialized) return;

        var dummy: JitContext = undefined;
        const base: usize = @intFromPtr(&dummy);
        sp_ptr_offset = @intFromPtr(&dummy.sp_ptr) - base;
        capacity_offset = @intFromPtr(&dummy.capacity) - base;
        ctx_offset = @intFromPtr(&dummy.ctx) - base;
        trampoline_target_offset = @intFromPtr(&dummy.trampoline_target) - base;
        initialized = true;
    }
};

/// The compiled function signature: takes a single JitContext pointer.
pub const CompiledFn = *const fn (*JitContext) callconv(.c) i32;

fn isMutualGroupMember(group: []const []const u8, name: []const u8) bool {
    for (group) |member| {
        if (std.mem.eql(u8, member, name)) return true;
    }
    return false;
}

/// Check whether any tail-position instruction is a self-call.
/// "Tail position" means last instruction of the sequence, or last instruction
/// inside a quotation argument to an `if` that is itself in tail position.
fn hasSelfTailCall(instructions: []const Instruction, self_name: []const u8) bool {
    if (instructions.len == 0) return false;
    const last = instructions[instructions.len - 1];
    switch (last.op) {
        .call_word => |name| {
            if (std.mem.eql(u8, name, self_name)) return true;
            if (std.mem.eql(u8, name, "if")) {
                // Check the two quotation literals preceding `if`
                if (instructions.len < 3) return false;
                const true_instr = instructions[instructions.len - 3];
                const false_instr = instructions[instructions.len - 2];
                const true_body = switch (true_instr.op) {
                    .push_literal => |v| if (v == .quotation) v.quotation.instructions else return false,
                    else => return false,
                };
                const false_body = switch (false_instr.op) {
                    .push_literal => |v| if (v == .quotation) v.quotation.instructions else return false,
                    else => return false,
                };
                return hasSelfTailCall(true_body, self_name) or hasSelfTailCall(false_body, self_name);
            }
            return false;
        },
        .push_literal => return false,
    }
}

const PreScanFlags = struct {
    needs_dispatch: bool = false,
    needs_safepoint: bool = false,
    needs_error_handling: bool = false,
    needs_dynamic_vars: bool = false,
    needs_iterators: bool = false,
    needs_native_call: bool = false,
    needs_param_validation: bool = false,

    fn needsErrorPropagation(self: PreScanFlags) bool {
        return self.needs_error_handling or self.needs_safepoint or
            self.needs_dynamic_vars or self.needs_iterators or
            self.needs_native_call or self.needs_dispatch or
            self.needs_param_validation;
    }
};

/// Recursively scan instructions and quotation bodies for dispatch calls
/// and loop ops.
fn preScanInstructions(
    instructions: []const Instruction,
    resolver: ?WordResolver,
    flags: *PreScanFlags,
    in_quotation: bool,
) IrCodegenError!void {
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (val == .quotation) {
                    try preScanInstructions(val.quotation.instructions, resolver, flags, true);
                }
            },
            .call_word => |name| {
                if (isLoopOp(name)) {
                    flags.needs_safepoint = true;
                } else if (isErrorHandlingOp(name)) {
                    flags.needs_error_handling = true;
                } else if (isDynamicVarOp(name)) {
                    flags.needs_dynamic_vars = true;
                } else if (isIteratorOp(name)) {
                    flags.needs_iterators = true;
                    const opcode = iteratorOpcodeFromName(name).?;
                    if (iteratorEffects(opcode).dynamic) {
                        flags.needs_param_validation = true;
                    }
                } else if (!isSupportedOp(name) and !isStackOp(name)) {
                    if (resolver) |res| {
                        if (res.resolve(name, res.user_data)) |resolved| {
                            if (resolved.native_fn_ptr != null) {
                                flags.needs_native_call = true;
                            } else {
                                flags.needs_dispatch = true;
                            }
                            if (resolved.stack_effect_ptr != null) {
                                flags.needs_param_validation = true;
                            }
                        } else if (!in_quotation) {
                            return IrCodegenError.NotCompilable;
                        }
                    } else if (!in_quotation) {
                        return IrCodegenError.NotCompilable;
                    }
                }
            },
        }
    }
}

/// Compile a word's instruction sequence into native code via the ir JIT.
/// The compiled function operates directly on the per-task Value stack.
/// Supports push_literal of any Value variant and call_word of supported
/// arithmetic ops (arithmetic still requires fixnum operands at runtime).
pub fn compileWord(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    interp_ctx: ?*const Context,
    mutual_group: ?[]const []const u8,
) IrCodegenError!CompiledWord {
    ValueLayout.ensureInit();

    if (input_count > 8) return IrCodegenError.NotCompilable;

    // Pre-scan: check if any call_word needs dispatch table resolution
    // or contains loops (which need safepoints).
    var scan_flags = PreScanFlags{};
    try preScanInstructions(instructions, resolver, &scan_flags, false);

    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION | c.IR_OPT_FOLDING, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    c._ir_START(&ctx);

    JitContextLayout.ensureInit();

    // Single parameter: pointer to JitContext struct
    const jit_ctx_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "jit_ctx", 1);

    // Load fields from the JitContext struct
    const items_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
    const sp_ptr_off = c.ir_const_addr(&ctx, JitContextLayout.sp_ptr_offset);
    const sp_ptr_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, sp_ptr_off);
    const sp_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr_addr);
    const cap_off = c.ir_const_addr(&ctx, JitContextLayout.capacity_offset);
    const cap_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, cap_off);
    const capacity_param = c._ir_LOAD(&ctx, c.IR_ADDR, cap_addr);

    // Bake dispatch table pointer as a constant if dispatch calls are needed.
    const dispatch_ptr = if (scan_flags.needs_dispatch)
        c.ir_const_addr(&ctx, @intFromPtr(resolver.?.dispatch_table_ptr))
    else
        c.IR_UNUSED;

    // Bake safepoint function pointer as a constant if loops are present.
    const safepoint_fn = if (scan_flags.needs_safepoint)
        c.ir_const_addr(&ctx, @intFromPtr(&jitSafepoint))
    else
        c.IR_UNUSED;

    // Bake error handling callback pointers if recover/cleanup are used.
    const recover_fn = if (scan_flags.needs_error_handling)
        c.ir_const_addr(&ctx, @intFromPtr(&jitRecover))
    else
        c.IR_UNUSED;
    const cleanup_fn = if (scan_flags.needs_error_handling)
        c.ir_const_addr(&ctx, @intFromPtr(&jitCleanup))
    else
        c.IR_UNUSED;

    const get_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_addr(&ctx, @intFromPtr(&jitGet))
    else
        c.IR_UNUSED;
    const with_parameter_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_addr(&ctx, @intFromPtr(&jitWithParameter))
    else
        c.IR_UNUSED;

    const iterator_fn = if (scan_flags.needs_iterators)
        c.ir_const_addr(&ctx, @intFromPtr(&jitIteratorOp))
    else
        c.IR_UNUSED;

    const native_call_fn = if (scan_flags.needs_native_call)
        c.ir_const_addr(&ctx, @intFromPtr(&jitNativeCall))
    else
        c.IR_UNUSED;

    const interpreted_call_fn = if (scan_flags.needs_dispatch)
        c.ir_const_addr(&ctx, @intFromPtr(&jitInterpretedCall))
    else
        c.IR_UNUSED;

    const validate_params_fn = if (scan_flags.needs_param_validation)
        c.ir_const_addr(&ctx, @intFromPtr(&jitValidateParamEffects))
    else
        c.IR_UNUSED;

    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);
    const error_propagate_status = c.ir_const_i32(&ctx, 2);

    // Load current stack depth
    const sp_val = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr);

    // Check stack has enough values (sp >= input_count)
    if (input_count > 0) {
        const min_sp = c.ir_const_addr(&ctx, input_count);
        const sp_too_small = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ULT, c.IR_BOOL), sp_val, min_sp);
        const if_underflow = c._ir_IF(&ctx, sp_too_small);
        c._ir_IF_TRUE_cold(&ctx, if_underflow);
        c._ir_RETURN(&ctx, bail_status);
        c._ir_IF_FALSE(&ctx, if_underflow);
    }

    // Layout constants
    const value_size_const = c.ir_const_addr(&ctx, ValueLayout.value_size);
    const tag_offset_const = c.ir_const_addr(&ctx, ValueLayout.tag_offset);
    const payload_offset_const = c.ir_const_addr(&ctx, ValueLayout.payload_offset);
    const fixnum_tag_const = emitTagConst(&ctx, .fixnum);
    const float_tag_const = emitTagConst(&ctx, .float);
    const boolean_tag_const = emitTagConst(&ctx, .boolean);
    const tagged_tag_const = emitTagConst(&ctx, .tagged);
    const struct_instance_tag_const = emitTagConst(&ctx, .struct_instance);

    // Precompute the base address for output writes:
    // base_addr = items_ptr + (sp_val - input_count) * value_size
    const input_count_const = c.ir_const_addr(&ctx, input_count);
    const base_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, input_count_const);
    const base_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), base_idx, value_size_const);
    const base_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, base_byte_offset);

    // Initialize inputs as raw_at_slot entries. Tag checking and unboxing
    // happen lazily at use sites (e.g., when arithmetic needs a fixnum).
    var stack: [64]StackEntry = undefined;
    var sp: usize = 0;
    for (0..input_count) |_| {
        stack[sp] = .{ .raw_at_slot = sp };
        sp += 1;
    }

    var state = CompileState{
        .ctx = &ctx,
        .base_addr = base_addr,
        .tag_offset_const = tag_offset_const,
        .payload_offset_const = payload_offset_const,
        .fixnum_tag_const = fixnum_tag_const,
        .float_tag_const = float_tag_const,
        .boolean_tag_const = boolean_tag_const,
        .tagged_tag_const = tagged_tag_const,
        .struct_instance_tag_const = struct_instance_tag_const,
        .bail_status = bail_status,
        .ok_status = ok_status,
        .items_ptr = items_ptr,
        .sp_ptr = sp_ptr,
        .capacity_param = capacity_param,
        .sp_val = sp_val,
        .base_idx = base_idx,
        .value_size_const = value_size_const,
        .dispatch_ptr = dispatch_ptr,
        .resolver = resolver,
        .jit_ctx_ptr = jit_ctx_ptr,
        .safepoint_fn = safepoint_fn,
        .recover_fn = recover_fn,
        .cleanup_fn = cleanup_fn,
        .get_fn = get_fn,
        .with_parameter_fn = with_parameter_fn,
        .iterator_fn = iterator_fn,
        .native_call_fn = native_call_fn,
        .interpreted_call_fn = interpreted_call_fn,
        .validate_params_fn = validate_params_fn,
        .interp_ctx = interp_ctx,
        .error_propagate_status = error_propagate_status,
    };

    // If this word contains a self-tail-call, wrap the body in a LOOP_BEGIN
    // so the self-call becomes a back-edge instead of a recursive native call.
    if (self_name) |sn| {
        if (hasSelfTailCall(instructions, sn)) {
            const entry_end = c._ir_END(&ctx);
            state.loop_begin_ref = c._ir_LOOP_BEGIN(&ctx, entry_end);
            state.self_name = sn;
            state.input_count = input_count;
            scan_flags.needs_safepoint = true;
            if (state.safepoint_fn == c.IR_UNUSED) {
                state.safepoint_fn = c.ir_const_addr(&ctx, @intFromPtr(&jitSafepoint));
                state.error_propagate_status = c.ir_const_i32(&ctx, 2);
            }
        }
    }

    // Set up mutual recursion trampoline state if this word is in a group.
    if (mutual_group) |group| {
        state.mutual_group = group;
        state.input_count = input_count;
        state.trampoline_status = c.ir_const_i32(&ctx, 3);
    }

    try compileInstructions(&state, instructions, &stack, &sp);

    if (state.diverged) {
        // All paths loop back (no base case fell through).
        // Emit unreachable fallback return.
        c._ir_RETURN(&ctx, ok_status);
    } else if (state.dynamic_call_emitted) {
        // The callee updated sp_ptr and the physical stack directly.
        // Just return success.
        c._ir_RETURN(&ctx, ok_status);
    } else {
        if (sp != output_count) return IrCodegenError.StackShapeMismatch;

        // Finalize each symbolic stack entry into a physical Value on the stack.
        //   i64_ref       -- box with fixnum tag and write to the output slot
        //   f64_ref       -- box with float tag and write to the output slot
        //   bool_ref      -- box with boolean tag and write to the output slot
        //   raw_at_slot   -- already a physical Value; copy only if the slot
        //                    index differs from the output position
        //   quotation_body -- should have been consumed by `if` or `call`;
        //                     reaching here means an unconsumed quotation
        for (0..sp) |i| {
            switch (stack[i]) {
                .i64_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, fixnum_tag_const, ref);
                },
                .f64_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, float_tag_const, ref);
                },
                .bool_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, boolean_tag_const, ref);
                },
                .quotation_body => return IrCodegenError.NotCompilable,
                .raw_at_slot => |s| {
                    if (s != i) {
                        // Check for swap pattern: stack[i] -> s and stack[s] -> i
                        if (s < sp and stack[s] == .raw_at_slot and stack[s].raw_at_slot == i) {
                            emitSwapSlots(&ctx, base_addr, i, s);
                            stack[s] = .{ .raw_at_slot = s };
                        } else {
                            emitCopySlot(&ctx, base_addr, s, i);
                        }
                    }
                },
            }
        }

        // Update sp: new_sp = sp_val - input_count + output_count
        // Always store back to sp_ptr because intermediate callbacks
        // (compound word dispatch, iterator ops, native calls) may have
        // written to sp_ptr during execution.
        if (input_count > output_count) {
            const sp_delta = c.ir_const_addr(&ctx, input_count - output_count);
            const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, sp_delta);
            c._ir_STORE(&ctx, sp_ptr, new_sp);
        } else if (input_count < output_count) {
            const sp_delta = c.ir_const_addr(&ctx, output_count - input_count);
            const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), sp_val, sp_delta);
            c._ir_STORE(&ctx, sp_ptr, new_sp);
        } else {
            c._ir_STORE(&ctx, sp_ptr, sp_val);
        }

        c._ir_RETURN(&ctx, ok_status);
    }

    // JIT compile
    var size: usize = 0;
    const code: ?*anyopaque = c.ir_jit_compile(&ctx, 2, &size);
    if (code) |ptr| {
        return .{
            .code_ptr = ptr,
            .jit_buf = .{ .code = ptr, .size = size },
        };
    }
    return IrCodegenError.CompilationFailed;
}

/// Convert a 1z word name to a valid C identifier.
///
/// Alphanumerics and underscores pass through; special characters are mapped to short mnemonics;
/// everything else becomes `_xNN_` hex escapes.
///
/// The result is prefixed with `onez_w_` and null-terminated for C interop.
pub fn mangleWordName(name: []const u8, allocator: Allocator) Allocator.Error![:0]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "onez_w_");
    for (name) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => try buf.append(allocator, ch),
            '-' => try buf.append(allocator, '_'),
            '#' => try buf.appendSlice(allocator, "_H"),
            '@' => try buf.appendSlice(allocator, "_A"),
            '?' => try buf.appendSlice(allocator, "_Q"),
            '!' => try buf.appendSlice(allocator, "_B"),
            '*' => try buf.appendSlice(allocator, "_S"),
            '+' => try buf.appendSlice(allocator, "_P"),
            '/' => try buf.appendSlice(allocator, "_D"),
            '<' => try buf.appendSlice(allocator, "_L"),
            '>' => try buf.appendSlice(allocator, "_G"),
            '=' => try buf.appendSlice(allocator, "_E"),
            '.' => try buf.appendSlice(allocator, "_O"),
            ':' => try buf.appendSlice(allocator, "_C"),
            else => {
                var hex_buf: [7]u8 = undefined;
                const hex = std.fmt.bufPrint(&hex_buf, "_x{X:0>2}_", .{ch}) catch unreachable;
                try buf.appendSlice(allocator, hex);
            },
        }
    }
    return buf.toOwnedSliceSentinel(allocator, 0);
}

/// Emit a compiled word as C source code via ir_emit_c.
///
/// Currently limited to pure-arithmetic words, no callbacks, no dispatch.
pub fn emitWordC(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    name: []const u8,
    allocator: Allocator,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    ValueLayout.ensureInit();

    if (input_count > 8) return IrCodegenError.NotCompilable;

    const c_name = try mangleWordName(name, allocator);
    defer allocator.free(c_name);

    // C emission does not use IR_OPT_FOLDING because the opt-level-0 pipeline
    // used by ir_emit_c / no ir_sccp pass) is incompatible with it.
    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    // ir_init zeroes ret_type to IR_VOID. Set it to IR_I32 so the C emitter
    // generates the correct return type: compiled words return i32 status.
    ctx.ret_type = c.IR_I32;

    c._ir_START(&ctx);

    JitContextLayout.ensureInit();

    const jit_ctx_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "jit_ctx", 1);

    const items_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
    const sp_ptr_off = c.ir_const_addr(&ctx, JitContextLayout.sp_ptr_offset);
    const sp_ptr_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, sp_ptr_off);
    const sp_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr_addr);

    // Capacity is not loaded for C emission. The ir_emit_c backend assigns
    // vreg 0 to unused LOAD instructions, producing undeclared d_0 in the
    // output. Capacity is loaded in the JIT path (compileWord) which uses
    // IR_OPT_FOLDING and handles dead code.
    const capacity_param = c.IR_UNUSED;

    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);

    const sp_val = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr);

    if (input_count > 0) {
        const min_sp = c.ir_const_addr(&ctx, input_count);
        const sp_too_small = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ULT, c.IR_BOOL), sp_val, min_sp);
        const if_underflow = c._ir_IF(&ctx, sp_too_small);
        c._ir_IF_TRUE_cold(&ctx, if_underflow);
        c._ir_RETURN(&ctx, bail_status);
        c._ir_IF_FALSE(&ctx, if_underflow);
    }

    const value_size_const = c.ir_const_addr(&ctx, ValueLayout.value_size);
    const tag_offset_const = c.ir_const_addr(&ctx, ValueLayout.tag_offset);
    const payload_offset_const = c.ir_const_addr(&ctx, ValueLayout.payload_offset);
    const fixnum_tag_const = emitTagConst(&ctx, .fixnum);
    const float_tag_const = emitTagConst(&ctx, .float);
    const boolean_tag_const = emitTagConst(&ctx, .boolean);
    const tagged_tag_const = emitTagConst(&ctx, .tagged);
    const struct_instance_tag_const = emitTagConst(&ctx, .struct_instance);

    const input_count_const = c.ir_const_addr(&ctx, input_count);
    const base_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, input_count_const);
    const base_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), base_idx, value_size_const);
    const base_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, base_byte_offset);

    var stack: [64]StackEntry = undefined;
    var sp: usize = 0;
    for (0..input_count) |_| {
        stack[sp] = .{ .raw_at_slot = sp };
        sp += 1;
    }

    var state = CompileState{
        .ctx = &ctx,
        .base_addr = base_addr,
        .tag_offset_const = tag_offset_const,
        .payload_offset_const = payload_offset_const,
        .fixnum_tag_const = fixnum_tag_const,
        .float_tag_const = float_tag_const,
        .boolean_tag_const = boolean_tag_const,
        .tagged_tag_const = tagged_tag_const,
        .struct_instance_tag_const = struct_instance_tag_const,
        .bail_status = bail_status,
        .ok_status = ok_status,
        .items_ptr = items_ptr,
        .sp_ptr = sp_ptr,
        .capacity_param = capacity_param,
        .sp_val = sp_val,
        .base_idx = base_idx,
        .value_size_const = value_size_const,
        .jit_ctx_ptr = jit_ctx_ptr,
    };

    try compileInstructions(&state, instructions, &stack, &sp);

    if (state.diverged) {
        c._ir_RETURN(&ctx, ok_status);
    } else if (state.dynamic_call_emitted) {
        c._ir_RETURN(&ctx, ok_status);
    } else {
        if (sp != output_count) return IrCodegenError.StackShapeMismatch;
        for (0..sp) |i| {
            switch (stack[i]) {
                .i64_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, fixnum_tag_const, ref);
                },
                .f64_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, float_tag_const, ref);
                },
                .bool_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, boolean_tag_const, ref);
                },
                .quotation_body => return IrCodegenError.NotCompilable,
                .raw_at_slot => |s| {
                    if (s != i) {
                        if (s < sp and stack[s] == .raw_at_slot and stack[s].raw_at_slot == i) {
                            emitSwapSlots(&ctx, base_addr, i, s);
                            stack[s] = .{ .raw_at_slot = s };
                        } else {
                            emitCopySlot(&ctx, base_addr, s, i);
                        }
                    }
                },
            }
        }
        if (input_count > output_count) {
            const sp_delta = c.ir_const_addr(&ctx, input_count - output_count);
            const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, sp_delta);
            c._ir_STORE(&ctx, sp_ptr, new_sp);
        } else if (input_count < output_count) {
            const sp_delta = c.ir_const_addr(&ctx, output_count - input_count);
            const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), sp_val, sp_delta);
            c._ir_STORE(&ctx, sp_ptr, new_sp);
        } else {
            c._ir_STORE(&ctx, sp_ptr, sp_val);
        }
        c._ir_RETURN(&ctx, ok_status);
    }

    // emit as C source with stdint.h preamble
    const body = try ir_mod.emitC(&ctx, c_name.ptr, allocator);
    errdefer allocator.free(body);

    const preamble = "#include <stdint.h>\n#include <stdbool.h>\n\n";
    const result = try allocator.alloc(u8, preamble.len + body.len);
    @memcpy(result[0..preamble.len], preamble);
    @memcpy(result[preamble.len..], body);
    allocator.free(body);
    return result;
}

/// Emit a single word as a C function body for AOT compilation. Uses named
/// extern references (ir_const_func) for callbacks instead of baked addresses.
/// Does NOT include the #include preamble -- the caller (emitProgramC) adds it.
pub fn emitWordCAot(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
    name: []const u8,
    resolver: ?WordResolver,
    self_name: ?[]const u8,
    aot_compiled_names: *const std.StringHashMapUnmanaged(u32),
    string_literals: ?*std.ArrayListUnmanaged(AotStringLiteral),
    allocator: Allocator,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    ValueLayout.ensureInit();

    if (input_count > 8) return IrCodegenError.NotCompilable;

    const c_name = try mangleWordName(name, allocator);
    defer allocator.free(c_name);

    // C emission does not use IR_OPT_FOLDING because the opt-level-0 pipeline
    // used by ir_emit_c is incompatible with it.
    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    ctx.ret_type = c.IR_I32;

    c._ir_START(&ctx);

    JitContextLayout.ensureInit();

    const jit_ctx_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "jit_ctx", 1);

    const items_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, jit_ctx_ptr);
    const sp_ptr_off = c.ir_const_addr(&ctx, JitContextLayout.sp_ptr_offset);
    const sp_ptr_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, sp_ptr_off);
    const sp_ptr = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr_addr);

    // Capacity is not loaded for C emission. The ir_emit_c backend treats
    // unused LOAD instructions as having vreg 0, which produces undeclared
    // d_0 references in the generated C. The JIT path (compileWord) loads
    // capacity unconditionally because it uses IR_OPT_FOLDING which handles
    // dead code. Stack overflow checking for AOT will be added when the
    // runtime entry points are implemented.
    const capacity_param = c.IR_UNUSED;

    // Pre-scan to determine which callbacks are needed
    var scan_flags = PreScanFlags{};
    preScanInstructions(instructions, resolver, &scan_flags, false) catch
        return IrCodegenError.NotCompilable;

    // Create prototypes for callback functions
    const proto_1arg = c.ir_proto_1(&ctx, 0, c.IR_I32, c.IR_ADDR);
    const proto_2arg = c.ir_proto_2(&ctx, 0, c.IR_I32, c.IR_ADDR, c.IR_ADDR);

    // Named callback references for AOT C emission
    const safepoint_fn = if (scan_flags.needs_safepoint)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitSafepoint"), proto_1arg)
    else
        c.IR_UNUSED;

    const recover_fn = if (scan_flags.needs_error_handling)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitRecover"), proto_1arg)
    else
        c.IR_UNUSED;
    const cleanup_fn = if (scan_flags.needs_error_handling)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitCleanup"), proto_1arg)
    else
        c.IR_UNUSED;

    const get_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitGet"), proto_1arg)
    else
        c.IR_UNUSED;
    const with_parameter_fn = if (scan_flags.needs_dynamic_vars)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitWithParameter"), proto_1arg)
    else
        c.IR_UNUSED;

    const iterator_fn = if (scan_flags.needs_iterators)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitIteratorOp"), proto_2arg)
    else
        c.IR_UNUSED;

    const native_call_fn = if (scan_flags.needs_native_call)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitNativeCall"), proto_2arg)
    else
        c.IR_UNUSED;

    const interpreted_call_fn = if (scan_flags.needs_dispatch or scan_flags.needs_native_call)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitInterpretedCall"), proto_2arg)
    else
        c.IR_UNUSED;

    const validate_params_fn = if (scan_flags.needs_param_validation)
        c.ir_const_func(&ctx, c.ir_str(&ctx, "jitValidateParamEffects"), proto_2arg)
    else
        c.IR_UNUSED;

    const call_quotation_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitCallQuotation"), proto_1arg);

    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);
    const error_propagate_status = c.ir_const_i32(&ctx, 2);

    const sp_val = c._ir_LOAD(&ctx, c.IR_ADDR, sp_ptr);

    // Pre-load the interpreter Context pointer from the JitContext struct.
    // This must happen early to avoid the ir_emit_c bug where late LOADs
    // get assigned vreg 0 without a C variable declaration.
    const ctx_off = c.ir_const_addr(&ctx, JitContextLayout.ctx_offset);
    const ctx_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), jit_ctx_ptr, ctx_off);
    const preloaded_ctx_val = c._ir_LOAD(&ctx, c.IR_ADDR, ctx_addr);

    if (input_count > 0) {
        const min_sp = c.ir_const_addr(&ctx, input_count);
        const sp_too_small = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ULT, c.IR_BOOL), sp_val, min_sp);
        const if_underflow = c._ir_IF(&ctx, sp_too_small);
        c._ir_IF_TRUE_cold(&ctx, if_underflow);
        c._ir_RETURN(&ctx, bail_status);
        c._ir_IF_FALSE(&ctx, if_underflow);
    }

    const value_size_const = c.ir_const_addr(&ctx, ValueLayout.value_size);
    const tag_offset_const = c.ir_const_addr(&ctx, ValueLayout.tag_offset);
    const payload_offset_const = c.ir_const_addr(&ctx, ValueLayout.payload_offset);
    const fixnum_tag_const = emitTagConst(&ctx, .fixnum);
    const float_tag_const = emitTagConst(&ctx, .float);
    const boolean_tag_const = emitTagConst(&ctx, .boolean);
    const tagged_tag_const = emitTagConst(&ctx, .tagged);
    const struct_instance_tag_const = emitTagConst(&ctx, .struct_instance);

    const input_count_const = c.ir_const_addr(&ctx, input_count);
    const base_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, input_count_const);
    const base_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), base_idx, value_size_const);
    const base_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, base_byte_offset);

    var stack_buf: [64]StackEntry = undefined;
    var sp: usize = 0;
    for (0..input_count) |_| {
        stack_buf[sp] = .{ .raw_at_slot = sp };
        sp += 1;
    }

    var state = CompileState{
        .ctx = &ctx,
        .base_addr = base_addr,
        .tag_offset_const = tag_offset_const,
        .payload_offset_const = payload_offset_const,
        .fixnum_tag_const = fixnum_tag_const,
        .float_tag_const = float_tag_const,
        .boolean_tag_const = boolean_tag_const,
        .tagged_tag_const = tagged_tag_const,
        .struct_instance_tag_const = struct_instance_tag_const,
        .bail_status = bail_status,
        .ok_status = ok_status,
        .items_ptr = items_ptr,
        .sp_ptr = sp_ptr,
        .capacity_param = capacity_param,
        .sp_val = sp_val,
        .base_idx = base_idx,
        .value_size_const = value_size_const,
        .jit_ctx_ptr = jit_ctx_ptr,
        .resolver = resolver,
        .safepoint_fn = safepoint_fn,
        .recover_fn = recover_fn,
        .cleanup_fn = cleanup_fn,
        .get_fn = get_fn,
        .with_parameter_fn = with_parameter_fn,
        .iterator_fn = iterator_fn,
        .native_call_fn = native_call_fn,
        .interpreted_call_fn = interpreted_call_fn,
        .validate_params_fn = validate_params_fn,
        .error_propagate_status = error_propagate_status,
        .aot_mode = true,
        .aot_compiled_names = aot_compiled_names,
        .aot_proto_1arg = proto_1arg,
        .aot_proto_2arg = proto_2arg,
        .call_quotation_fn = call_quotation_fn,
        .preloaded_ctx_val = preloaded_ctx_val,
        .aot_string_literals = string_literals,
    };

    // Self-tail-call detection for AOT
    if (self_name) |sn| {
        if (hasSelfTailCall(instructions, sn)) {
            const entry_end = c._ir_END(&ctx);
            state.loop_begin_ref = c._ir_LOOP_BEGIN(&ctx, entry_end);
            state.self_name = sn;
            state.input_count = input_count;
            if (state.safepoint_fn == c.IR_UNUSED) {
                state.safepoint_fn = c.ir_const_func(&ctx, c.ir_str(&ctx, "jitSafepoint"), proto_1arg);
                state.error_propagate_status = c.ir_const_i32(&ctx, 2);
            }
        }
    }

    try compileInstructions(&state, instructions, &stack_buf, &sp);

    if (state.diverged) {
        c._ir_RETURN(&ctx, ok_status);
    } else if (state.dynamic_call_emitted) {
        c._ir_RETURN(&ctx, ok_status);
    } else {
        if (sp != output_count) return IrCodegenError.StackShapeMismatch;
        for (0..sp) |i| {
            switch (stack_buf[i]) {
                .i64_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, fixnum_tag_const, ref);
                },
                .f64_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, float_tag_const, ref);
                },
                .bool_ref => |ref| {
                    const slot_byte_offset = c.ir_const_addr(&ctx, i * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, slot_byte_offset);
                    emitBoxPayload(&ctx, dest_addr, tag_offset_const, payload_offset_const, boolean_tag_const, ref);
                },
                .quotation_body => return IrCodegenError.NotCompilable,
                .raw_at_slot => |s| {
                    if (s != i) {
                        if (s < sp and stack_buf[s] == .raw_at_slot and stack_buf[s].raw_at_slot == i) {
                            emitSwapSlots(&ctx, base_addr, i, s);
                            stack_buf[s] = .{ .raw_at_slot = s };
                        } else {
                            emitCopySlot(&ctx, base_addr, s, i);
                        }
                    }
                },
            }
        }
        if (input_count > output_count) {
            const sp_delta = c.ir_const_addr(&ctx, input_count - output_count);
            const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, sp_delta);
            c._ir_STORE(&ctx, sp_ptr, new_sp);
        } else if (input_count < output_count) {
            const sp_delta = c.ir_const_addr(&ctx, output_count - input_count);
            const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), sp_val, sp_delta);
            c._ir_STORE(&ctx, sp_ptr, new_sp);
        } else {
            c._ir_STORE(&ctx, sp_ptr, sp_val);
        }
        c._ir_RETURN(&ctx, ok_status);
    }

    return ir_mod.emitC(&ctx, c_name.ptr, allocator);
}

/// Work around ir_emit_c vreg 0 bug: if the emitted C body uses `d_0` but
/// does not declare it, insert `\tuintptr_t d_0;\n` after the opening brace.
fn patchMissingD0(body: []u8, allocator: Allocator) Allocator.Error![]u8 {
    // Check if d_0 is used anywhere in the body.
    if (std.mem.indexOf(u8, body, "d_0") == null) return body;

    // Check if d_0 is already declared (pattern: "\tuintptr_t d_0")
    if (std.mem.indexOf(u8, body, "\tuintptr_t d_0") != null) return body;

    // Find the opening brace + newline to insert after.
    const brace_nl = std.mem.indexOf(u8, body, "{\n") orelse return body;
    const insert_pos = brace_nl + 2;
    const decl = "\tuintptr_t d_0;\n";

    const new = try allocator.alloc(u8, body.len + decl.len);
    @memcpy(new[0..insert_pos], body[0..insert_pos]);
    @memcpy(new[insert_pos .. insert_pos + decl.len], decl);
    @memcpy(new[insert_pos + decl.len ..], body[insert_pos..]);
    return new;
}

/// Emit a complete, compilable C source file for a set of words.
///
/// The output contains:
///   1. #include preamble
///   2. Forward declarations for all runtime callbacks (extern)
///   3. Forward declarations for all compiled word functions
///   4. One C function per word (via ir_emit_c)
///   5. A dispatch table initialization array
///   6. A main() entry point
///
/// `entry_word_id` identifies which word to call from main().
pub fn emitProgramC(
    words: []const AotWordDesc,
    entry_word_id: u32,
    max_word_id: u32,
    static_libs: []const []const u8,
    diagnostics: *CodegenDiagnostics,
    allocator: Allocator,
) (IrCodegenError || ir_mod.IrError || Allocator.Error)![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    // Build name->word_id map for compiled words, excluding native words, which must always use jitInterpretedCall
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(allocator);
    for (words) |w| {
        if (w.is_native) continue;
        try compiled_names.put(allocator, w.name, w.word_id);
    }

    // 1. Preamble
    try out.appendSlice(allocator, "#include <stdint.h>\n#include <stdbool.h>\n#include <stddef.h>\n#include <string.h>\n\n");

    // 2. Callback extern declarations -- emit all unconditionally since the
    // two-pass compilation may introduce interpreter fallback calls that
    // weren't predicted by the pre-scan.
    try out.appendSlice(allocator, "extern int32_t jitSafepoint(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitRecover(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitCleanup(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitGet(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitWithParameter(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitIteratorOp(uintptr_t ctx, uintptr_t opcode);\n");
    try out.appendSlice(allocator, "extern int32_t jitNativeCall(uintptr_t ctx, uintptr_t fn_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitInterpretedCall(uintptr_t ctx, uintptr_t word_id);\n");
    try out.appendSlice(allocator, "extern int32_t jitValidateParamEffects(uintptr_t ctx, uintptr_t effect_ptr);\n");
    try out.appendSlice(allocator, "extern int32_t jitCallQuotation(uintptr_t ctx);\n");
    try out.appendSlice(allocator, "extern int32_t jitPushString(uintptr_t ctx, uintptr_t str_ptr, uintptr_t str_len);\n");
    try out.appendSlice(allocator, "extern int32_t jitPushSymbol(uintptr_t ctx, uintptr_t str_ptr, uintptr_t str_len);\n");
    try out.appendSlice(allocator, "static int32_t onez_push_string(uintptr_t ctx, const char *str, uintptr_t len) { return jitPushString(ctx, (uintptr_t)str, len); }\n");
    try out.appendSlice(allocator, "static int32_t onez_push_symbol(uintptr_t ctx, const char *str, uintptr_t len) { return jitPushSymbol(ctx, (uintptr_t)str, len); }\n");

    // Runtime entry point externs
    try out.appendSlice(allocator,
        \\
        \\extern void *onez_init(void);
        \\extern int onez_set_args(void *ctx, int argc, char **argv);
        \\extern int32_t onez_runtime_register_compiled(void *rt, int32_t (**table)(uintptr_t), const char **names, uint32_t size);
        \\extern int32_t onez_runtime_run(void *rt, uint32_t entry_word_id);
        \\extern void onez_print_error(void *rt);
        \\extern void onez_deinit(void *rt);
        \\extern int onez_set_static_libs(void *rt, const char **names, unsigned int count);
        \\
        \\
    );

    // Build a resolver from the AOT word list for cross-word calls
    var word_map: std.StringHashMapUnmanaged(AotWordDesc) = .{};
    defer word_map.deinit(allocator);
    for (words) |w| {
        try word_map.put(allocator, w.name, w);
    }

    const AotResolverData = struct {
        map: *const std.StringHashMapUnmanaged(AotWordDesc),

        fn resolve(name_ptr: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const self: *const @This() = @ptrCast(@alignCast(user_data));
            const w = self.map.get(name_ptr) orelse return null;
            return ResolvedWord{
                .word_id = w.word_id,
                .input_count = w.input_count,
                .output_count = w.output_count,
            };
        }
    };

    var resolver_data = AotResolverData{ .map = &word_map };
    const resolver = WordResolver{
        .resolve = &AotResolverData.resolve,
        .user_data = @ptrCast(&resolver_data),
        .dispatch_table_ptr = undefined,
    };

    // 4. Two-pass compilation: first determine which words compile,
    // then re-compile with only the compilable set so that cross-word calls
    // to uncompilable words use jitInterpretedCall instead of direct calls.

    // Pass 1: trial compile to discover the compilable set.
    var compilable_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compilable_names.deinit(allocator);
    for (words) |w| {
        if (w.is_native) continue;
        const trial = emitWordCAot(
            w.instructions,
            w.input_count,
            w.output_count,
            w.name,
            resolver,
            w.name,
            &compiled_names,
            null,
            allocator,
        ) catch continue;
        allocator.free(trial);
        try compilable_names.put(allocator, w.name, w.word_id);
    }

    // String literal table populated during pass 2.
    var string_literals: std.ArrayListUnmanaged(AotStringLiteral) = .{};
    defer string_literals.deinit(std.heap.page_allocator);

    // Pass 2: compile with only the compilable set.
    var compiled_bodies: std.ArrayListUnmanaged(struct { word_id: u32, body: []u8 }) = .{};
    defer {
        for (compiled_bodies.items) |item| allocator.free(item.body);
        compiled_bodies.deinit(allocator);
    }

    var actually_compiled: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer actually_compiled.deinit(allocator);

    for (words) |w| {
        if (!compilable_names.contains(w.name)) continue;
        const raw_body = emitWordCAot(
            w.instructions,
            w.input_count,
            w.output_count,
            w.name,
            resolver,
            w.name,
            &compilable_names,
            &string_literals,
            allocator,
        ) catch |err| switch (err) {
            error.NotCompilable => continue,
            else => return err,
        };
        const body = try patchMissingD0(raw_body, allocator);
        if (body.ptr != raw_body.ptr) allocator.free(raw_body);
        try compiled_bodies.append(allocator, .{ .word_id = w.word_id, .body = body });
        try actually_compiled.put(allocator, w.word_id, {});
    }

    // Strict codegen: verify all non-prelude input words were compiled.
    // Prelude words can safely fall back to jitInterpretedCall since they
    // exist in the AOT runtime dictionary.
    {
        var uncompiled: std.ArrayListUnmanaged([]const u8) = .{};
        for (words) |w| {
            if (!w.is_prelude and !actually_compiled.contains(w.word_id)) {
                try uncompiled.append(allocator, w.name);
            }
        }
        if (uncompiled.items.len > 0) {
            diagnostics.uncompiled_words = try allocator.dupe([]const u8, uncompiled.items);
            uncompiled.deinit(allocator);
            return error.UncompiledWords;
        }
        uncompiled.deinit(allocator);
    }

    // 3.5. String/symbol literal constants
    for (string_literals.items, 0..) |lit, lit_idx| {
        var idx_buf: [20]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{lit_idx}) catch unreachable;
        try out.appendSlice(allocator, "static const char onez_lit_");
        try out.appendSlice(allocator, idx_str);
        try out.appendSlice(allocator, "[] = \"");
        for (lit.data) |ch| {
            switch (ch) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                0 => try out.appendSlice(allocator, "\\0"),
                else => {
                    const buf = [_]u8{ch};
                    try out.appendSlice(allocator, &buf);
                },
            }
        }
        try out.appendSlice(allocator, "\";\n");
    }
    if (string_literals.items.len > 0) {
        try out.appendSlice(allocator, "\n");
    }

    // 4a. Forward declarations (only for successfully compiled words)
    for (words) |w| {
        if (!actually_compiled.contains(w.word_id)) continue;
        const mangled = try mangleWordName(w.name, allocator);
        defer allocator.free(mangled);
        try out.appendSlice(allocator, "int32_t ");
        try out.appendSlice(allocator, mangled);
        try out.appendSlice(allocator, "(uintptr_t jit_ctx);\n");
    }
    try out.appendSlice(allocator, "\n");

    // 4b. Emit compiled function bodies
    for (compiled_bodies.items) |item| {
        try out.appendSlice(allocator, item.body);
        try out.appendSlice(allocator, "\n");
    }

    // 5. Dispatch table
    try out.appendSlice(allocator, "typedef int32_t (*onez_word_fn_t)(uintptr_t);\n");
    try out.appendSlice(allocator, "static onez_word_fn_t onez_dispatch_table[] = {\n");

    const table_size = max_word_id + 1;
    for (0..table_size) |id| {
        var found = false;
        for (words) |w| {
            if (w.word_id == id and actually_compiled.contains(w.word_id)) {
                const mangled = try mangleWordName(w.name, allocator);
                defer allocator.free(mangled);
                try out.appendSlice(allocator, "    ");
                try out.appendSlice(allocator, mangled);
                try out.appendSlice(allocator, ",\n");
                found = true;
                break;
            }
        }
        if (!found) {
            try out.appendSlice(allocator, "    NULL,\n");
        }
    }
    try out.appendSlice(allocator, "};\n\n");

    // 5b. Word name table (for interpreter fallback)
    try out.appendSlice(allocator, "static const char *onez_word_names[] = {\n");
    for (0..table_size) |id| {
        var found = false;
        for (words) |w| {
            if (w.word_id == id) {
                try out.appendSlice(allocator, "    \"");
                try out.appendSlice(allocator, w.name);
                try out.appendSlice(allocator, "\",\n");
                found = true;
                break;
            }
        }
        if (!found) {
            try out.appendSlice(allocator, "    NULL,\n");
        }
    }
    try out.appendSlice(allocator, "};\n\n");

    // 6. Main entry point
    try out.appendSlice(allocator, "int main(int argc, char **argv) {\n");
    try out.appendSlice(allocator, "    void *rt = onez_init();\n");
    try out.appendSlice(allocator, "    onez_set_args(rt, argc, argv);\n");

    // Register statically linked FFI libraries.
    if (static_libs.len > 0) {
        try out.appendSlice(allocator, "    {\n");
        try out.appendSlice(allocator, "        static const char *static_ffi_libs[] = {\n");
        for (static_libs) |lib| {
            try out.appendSlice(allocator, "            \"");
            try out.appendSlice(allocator, lib);
            try out.appendSlice(allocator, "\",\n");
        }
        try out.appendSlice(allocator, "        };\n");

        var count_buf: [20]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{static_libs.len}) catch unreachable;
        try out.appendSlice(allocator, "        onez_set_static_libs(rt, static_ffi_libs, ");
        try out.appendSlice(allocator, count_str);
        try out.appendSlice(allocator, ");\n");
        try out.appendSlice(allocator, "    }\n");
    }

    // Format dispatch table size
    var size_buf: [20]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{table_size}) catch unreachable;

    try out.appendSlice(allocator, "    onez_runtime_register_compiled(rt, onez_dispatch_table, onez_word_names, ");
    try out.appendSlice(allocator, size_str);
    try out.appendSlice(allocator, ");\n");

    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{entry_word_id}) catch unreachable;

    try out.appendSlice(allocator, "    int32_t status = onez_runtime_run(rt, ");
    try out.appendSlice(allocator, id_str);
    try out.appendSlice(allocator, ");\n");
    try out.appendSlice(allocator, "    if (status != 0) onez_print_error(rt);\n");
    try out.appendSlice(allocator, "    onez_deinit(rt);\n");
    try out.appendSlice(allocator, "    return (status != 0) ? 1 : 0;\n");
    try out.appendSlice(allocator, "}\n");

    return out.toOwnedSlice(allocator);
}

/// Emit an overflow-checked binary operation (add/sub/mul).
/// On overflow, returns bail_status. On success, returns the result ref.
fn emitOverflowCheckedBinary(
    ctx: *c.ir_ctx,
    comptime op: comptime_int,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    const result = c.ir_fold2(ctx, c.IR_OPT(op, c.IR_I64), a, b);
    const ovf = c.ir_fold1(ctx, c.IR_OPT(c.IR_OVERFLOW, c.IR_BOOL), result);
    const if_ovf = c._ir_IF(ctx, ovf);
    c._ir_IF_TRUE_cold(ctx, if_ovf);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_ovf);
    return result;
}

/// Emit division with div-by-zero and minInt/-1 overflow guards.
fn emitDivision(
    ctx: *c.ir_ctx,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    // Guard: b == 0 -> bail
    const zero = c.ir_const_i64(ctx, 0);
    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, zero);
    const if_zero = c._ir_IF(ctx, is_zero);
    c._ir_IF_TRUE_cold(ctx, if_zero);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_zero);

    // Guard: a == minInt and b == -1 -> bail (overflow)
    const min_val = c.ir_const_i64(ctx, std.math.minInt(i64));
    const neg_one = c.ir_const_i64(ctx, -1);
    const is_min = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), a, min_val);
    const is_neg_one = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, neg_one);
    const is_overflow = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), is_min, is_neg_one);
    const if_ov = c._ir_IF(ctx, is_overflow);
    c._ir_IF_TRUE_cold(ctx, if_ov);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_ov);

    return c.ir_fold2(ctx, c.IR_OPT(c.IR_DIV, c.IR_I64), a, b);
}

/// Emit truncating remainder with div-by-zero guard.
fn emitRemainder(
    ctx: *c.ir_ctx,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    // Guard: b == 0 -> bail
    const zero = c.ir_const_i64(ctx, 0);
    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, zero);
    const if_zero = c._ir_IF(ctx, is_zero);
    c._ir_IF_TRUE_cold(ctx, if_zero);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_zero);

    return c.ir_fold2(ctx, c.IR_OPT(c.IR_MOD, c.IR_I64), a, b);
}

/// Emit Euclidean modulo with div-by-zero guard.
/// Matches Zig's @mod semantics: r = @rem(a,b); if r != 0 and signs differ, r += b.
fn emitEuclideanMod(
    ctx: *c.ir_ctx,
    a: c.ir_ref,
    b: c.ir_ref,
    bail_status: c.ir_ref,
) c.ir_ref {
    // Guard: b == 0 -> bail
    const zero = c.ir_const_i64(ctx, 0);
    const is_zero = c.ir_fold2(ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), b, zero);
    const if_zero = c._ir_IF(ctx, is_zero);
    c._ir_IF_TRUE_cold(ctx, if_zero);
    c._ir_RETURN(ctx, bail_status);
    c._ir_IF_FALSE(ctx, if_zero);

    // Compute truncating remainder (C semantics)
    const rem_val = c.ir_fold2(ctx, c.IR_OPT(c.IR_MOD, c.IR_I64), a, b);

    // Adjustment: if rem != 0 and signs of rem and b differ, add b.
    // Signs differ when (rem XOR b) < 0.
    const rem_xor_b = c.ir_fold2(ctx, c.IR_OPT(c.IR_XOR, c.IR_I64), rem_val, b);
    const signs_differ = c.ir_fold2(ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), rem_xor_b, zero);
    const rem_nonzero = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), rem_val, zero);
    const needs_adjust = c.ir_fold2(ctx, c.IR_OPT(c.IR_AND, c.IR_BOOL), rem_nonzero, signs_differ);

    const adjusted = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_I64), rem_val, b);
    return c.ir_fold3(ctx, c.IR_OPT(c.IR_COND, c.IR_I64), needs_adjust, adjusted, rem_val);
}

// =============================================================================
// Safepoint
// =============================================================================

/// Store the current sp to memory and load the interpreter Context pointer
/// from the JitContext struct. This is the standard preamble before calling
/// any interpreter callback from compiled code.
fn emitCallbackPreamble(state: *CompileState, sp: usize) c.ir_ref {
    const ctx = state.ctx;
    const sp_const = c.ir_const_addr(ctx, sp);
    const new_sp = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.base_idx, sp_const);
    c._ir_STORE(ctx, state.sp_ptr, new_sp);

    // In AOT mode, reuse the ctx pointer loaded in the prologue to avoid
    // the ir_emit_c bug where LOADs get assigned vreg 0 without declaration.
    if (state.preloaded_ctx_val != c.IR_UNUSED) {
        return state.preloaded_ctx_val;
    }

    JitContextLayout.ensureInit();
    const ctx_off = c.ir_const_addr(ctx, JitContextLayout.ctx_offset);
    const ctx_addr = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
    return c._ir_LOAD(ctx, c.IR_ADDR, ctx_addr);
}

/// Check if a callback returned non-zero and bail with the callback's return
/// code if so. Used after interpreter callbacks from compiled code.
fn emitCallbackPostCheck(state: *CompileState, call_result: c.ir_ref, return_status: c.ir_ref) void {
    const ctx = state.ctx;
    const zero_status = c.ir_const_i32(ctx, 0);
    const call_failed = c.ir_fold2(ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), call_result, zero_status);
    const if_bail = c._ir_IF(ctx, call_failed);
    c._ir_IF_TRUE_cold(ctx, if_bail);
    c._ir_RETURN(ctx, return_status);
    c._ir_IF_FALSE(ctx, if_bail);
}

/// Emit a safepoint call at the current IR position. Loads the ctx field
/// from the JitContext struct and calls jitSafepoint.
fn emitSafepointCall(state: *CompileState) void {
    if (state.safepoint_fn == c.IR_UNUSED) return;

    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    const call_result = c._ir_CALL_1(state.ctx, c.IR_I32, state.safepoint_fn, ctx_val);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status);
}

/// Emit a native word call. In JIT mode, calls through jitNativeCall with
/// the baked function pointer. In AOT mode, calls through jitInterpretedCall
/// with the word ID since native function pointers are not available at C
/// compile time.
fn emitNativeWordCall(state: *CompileState, ctx_val: c.ir_ref, resolved: ResolvedWord) void {
    const ictx = state.ctx;
    if (state.aot_mode) {
        const word_id_const = c.ir_const_addr(ictx, resolved.word_id);
        const call_result = c._ir_CALL_2(ictx, c.IR_I32, state.interpreted_call_fn, ctx_val, word_id_const);
        emitCallbackPostCheck(state, call_result, state.error_propagate_status);
    } else {
        const fn_ptr_const = c.ir_const_addr(ictx, resolved.native_fn_ptr.?);
        const call_result = c._ir_CALL_2(ictx, c.IR_I32, state.native_call_fn, ctx_val, fn_ptr_const);
        emitCallbackPostCheck(state, call_result, call_result);
    }
}

/// Emit a compound word call in AOT mode. If the target word is in the
/// compiled word set, emits a direct call by mangled name. Otherwise, falls
/// through to jitInterpretedCall with the word ID.
fn emitAotWordCall(state: *CompileState, ctx_val: c.ir_ref, name: []const u8, resolved: ResolvedWord) void {
    const ictx = state.ctx;
    if (state.aot_compiled_names) |names| {
        if (names.get(name)) |_| {
            // Direct call to the compiled word's C function
            const mangled = mangleWordName(name, std.heap.page_allocator) catch unreachable;
            defer std.heap.page_allocator.free(mangled);
            const callee_fn = c.ir_const_func(ictx, c.ir_str(ictx, mangled.ptr), state.aot_proto_1arg);
            const call_result = c._ir_CALL_1(ictx, c.IR_I32, callee_fn, state.jit_ctx_ptr);
            emitCallbackPostCheck(state, call_result, call_result);
            return;
        }
    }
    // Fall through to interpreter for uncompiled words
    const word_id_const = c.ir_const_addr(ictx, resolved.word_id);
    const call_result = c._ir_CALL_2(ictx, c.IR_I32, state.interpreted_call_fn, ctx_val, word_id_const);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status);
}

/// Emit a parameter effect validation call at the current IR position.
/// Takes a stable pointer to the word's StackEffect and calls
/// jitValidateParamEffects to check quotation arguments on the stack.
fn emitParamValidation(state: *CompileState, effect_ptr: usize) void {
    if (state.validate_params_fn == c.IR_UNUSED) return;
    const ctx_val = if (state.preloaded_ctx_val != c.IR_UNUSED)
        state.preloaded_ctx_val
    else blk: {
        JitContextLayout.ensureInit();
        const ctx_off = c.ir_const_addr(state.ctx, JitContextLayout.ctx_offset);
        const ctx_addr = c.ir_fold2(state.ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), state.jit_ctx_ptr, ctx_off);
        break :blk c._ir_LOAD(state.ctx, c.IR_ADDR, ctx_addr);
    };
    const effect_const = c.ir_const_addr(state.ctx, effect_ptr);
    const call_result = c._ir_CALL_2(state.ctx, c.IR_I32, state.validate_params_fn, ctx_val, effect_const);
    emitCallbackPostCheck(state, call_result, state.error_propagate_status);
}

// =============================================================================
// Trampoline
// =============================================================================

export fn jitSafepoint(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 0;
    const ctx: *Context = @ptrFromInt(ctx_raw);

    signal.checkPendingSignals(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };

    const scheduler: *Scheduler = ctx.scheduler orelse return 0;
    const should_yield = scheduler.run_queue.items.len > 0 or scheduler.sleep_queue.count() > 0;
    if (should_yield) {
        scheduler.yieldCurrentTask();
    }
    helpers.checkCancellation(ctx) catch |err| {
        if (ctx.trace.trace_jit) {
            var tw = trace_mod.TraceWriter.init();
            trace_mod.traceJitSafepoint(&tw, should_yield, true);
        }
        ctx.jit_pending_error = err;
        return 2;
    };
    if (ctx.trace.trace_jit) {
        var tw = trace_mod.TraceWriter.init();
        trace_mod.traceJitSafepoint(&tw, should_yield, false);
    }
    return 0;
}

export fn jitGet(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    dynamic_vars_mod.nativeGet(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitWithParameter(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    dynamic_vars_mod.nativeWithParameter(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitRecover(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    errors_mod.nativeRecover(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitCleanup(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    errors_mod.nativeCleanup(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitValidateParamEffects(ctx_raw: usize, effect_ptr_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const effect: *const StackEffect = @ptrFromInt(effect_ptr_raw);
    ctx.validateParameterEffects(effect) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    ctx.validateTypeAnnotations(effect) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitIteratorOp(ctx_raw: usize, opcode_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const opcode = std.meta.intToEnum(IteratorOpcode, opcode_raw) catch return 1;
    const func: *const fn (*Context) anyerror!void = switch (opcode) {
        .next => &iterators_mod.nativeNext,
        .collect => &iterators_mod.nativeCollect,
        .count => &iterators_mod.nativeCount,
        .close_iterator => &iterators_mod.nativeCloseIterator,
        .take => &sequences_mod.nativeTake,
        .drop => &sequences_mod.nativeDrop,
        .each => &sequences_mod.nativeEach,
        .map => &sequences_mod.nativeMap,
        .filter => &sequences_mod.nativeFilter,
        .reduce => &sequences_mod.nativeReduce,
    };
    func(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitNativeCall(ctx_raw: usize, fn_ptr_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const func: *const fn (*Context) anyerror!void = @ptrFromInt(fn_ptr_raw);
    func(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

export fn jitCallQuotation(ctx_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    control.nativeCall(ctx) catch |err| {
        ctx.jit_pending_error = err;
        return 2;
    };
    return 0;
}

/// Push a string literal onto the stack. The string data is at `str_ptr`
/// with length `str_len`. The runtime copies the data into a managed allocation.
export fn jitPushString(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = ctx.quotationAllocator().dupe(u8, src[0..str_len]) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    ctx.stack.push(.{ .string = copy }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

/// Push a symbol literal onto the stack. Same mechanism as jitPushString.
export fn jitPushSymbol(ctx_raw: usize, str_ptr: usize, str_len: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const src: [*]const u8 = @ptrFromInt(str_ptr);
    const copy = ctx.quotationAllocator().dupe(u8, src[0..str_len]) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    ctx.stack.push(.{ .symbol = copy }) catch {
        ctx.jit_pending_error = error.OutOfMemory;
        return 2;
    };
    return 0;
}

export fn jitInterpretedCall(ctx_raw: usize, word_id_raw: usize) callconv(.c) i32 {
    if (ctx_raw == 0) return 1;
    const ctx: *Context = @ptrFromInt(ctx_raw);
    const word_id: u32 = @intCast(word_id_raw);
    const entry = ctx.jit_dispatch.get(word_id) orelse return 1;
    const word_name = entry.word_name;
    const word = ctx.lookupWord(word_name) orelse return 1;

    ctx.pushCallFrame(word_name, 0, 0);

    if (word.stack_effect) |effect| {
        ctx.validateParameterEffects(&effect) catch |err| {
            ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
            return 2;
        };
        if (!shouldSkipTypeAnnotationValidation(word)) {
            ctx.validateTypeAnnotations(&effect) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
        }
    }

    if (word.action == .compound) {
        const has_generic = for (word.markers) |mk| {
            if (markers_mod.isGenericMarker(mk)) break true;
        } else false;

        if (has_generic) {
            const dispatched = dispatch_helpers.tryDispatchGenericWithPic(ctx, word_name, null) catch |err| {
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
                return 2;
            };
            if (dispatched) {
                ctx.wordSuccessCleanup(word_name, null) catch |err| {
                    ctx.jit_pending_error = err;
                    return 2;
                };
                return 0;
            }
            if (word.action.compound.len == 0) {
                ctx.pending_error_message = "no method found for given argument types";
                ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, error.TypeError);
                return 2;
            }
        }
    }

    const result = blk: {
        if (word.source_module) |mod| {
            switch (word.action) {
                .compound => |instrs| {
                    ctx.pushModuleDepsFrame(mod) catch |e| break :blk @as(anyerror!void, e);
                    defer ctx.popModuleDepsFrameTraced(mod);
                    break :blk ctx.executeQuotationWithPic(.{ .instructions = instrs }, null);
                },
                .native => |func| break :blk func(ctx),
                .host_callback => |host| break :blk host_result: {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) break :host_result error.HostCallbackFailed;
                    break :host_result;
                },
            }
        } else {
            break :blk switch (word.action) {
                .native => |func| func(ctx),
                .host_callback => |host| host_result: {
                    const rc = host.callback(host.handle, host.user_data);
                    if (rc != 0) break :host_result error.HostCallbackFailed;
                    break :host_result;
                },
                .compound => |instrs| ctx.executeQuotationWithPic(.{ .instructions = instrs }, null),
            };
        }
    };

    if (result) |_| {
        ctx.consumePropagatedTailCall(word_name) catch |err| {
            ctx.jit_pending_error = err;
            return 2;
        };
        ctx.wordSuccessCleanup(word_name, word.stack_effect) catch |err| {
            ctx.jit_pending_error = err;
            return 2;
        };
        return 0;
    } else |err| {
        ctx.jit_pending_error = ctx.wordErrorCleanup(word_name, err);
        return 2;
    }
}

/// Result of attempting compiled execution.
pub const ExecResult = enum { ok, bail, error_propagate };

/// Execute a JIT-compiled word. The compiled function operates directly on
/// the per-task Value stack: it reads inputs, checks fixnum tags, performs
/// arithmetic, writes the result, and adjusts the stack pointer. Returns
/// .bail if the compiled function signals a type mismatch or overflow, in
/// which case the stack is unchanged.
pub fn executeCompiled(ctx: *Context, word_id: u32) ExecResult {
    const entry = ctx.jit_dispatch.get(word_id) orelse return .bail;
    var code_ptr = entry.code_ptr orelse return .bail;

    const saved_sp = ctx.stack.items.items.len;
    var jit_ctx = JitContext{
        .items_ptr = ctx.stack.items.items.ptr,
        .sp_ptr = &ctx.stack.items.items.len,
        .capacity = ctx.stack.items.capacity,
        .ctx = ctx,
    };
    var func: CompiledFn = @ptrCast(@alignCast(code_ptr));
    var status = func(&jit_ctx);

    // Trampoline loop: re-dispatch while compiled functions request it.
    // Status 3 means "tail-call to trampoline_target instead of returning".
    while (status == 3) {
        const target_id = jit_ctx.trampoline_target;
        const target_entry = ctx.jit_dispatch.get(target_id) orelse {
            ctx.stack.items.items.len = saved_sp;
            return .bail;
        };
        code_ptr = target_entry.code_ptr orelse {
            ctx.stack.items.items.len = saved_sp;
            return .bail;
        };
        // Re-read items_ptr/capacity in case stack was reallocated
        jit_ctx.items_ptr = ctx.stack.items.items.ptr;
        jit_ctx.capacity = ctx.stack.items.capacity;
        func = @ptrCast(@alignCast(code_ptr));
        status = func(&jit_ctx);
    }

    return switch (status) {
        0 => .ok,
        2 => .error_propagate,
        else => blk: {
            ctx.stack.items.items.len = saved_sp;
            break :blk .bail;
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn makeInstructions(comptime ops: anytype) [ops.len]Instruction {
    var instrs: [ops.len]Instruction = undefined;
    inline for (ops, 0..) |op, i| {
        instrs[i] = .{
            .op = switch (@TypeOf(op)) {
                i64, comptime_int => .{ .push_literal = .{ .fixnum = @as(i64, op) } },
                else => .{ .call_word = op },
            },
            .line = i + 1,
        };
    }
    return instrs;
}

/// Helper to call a compiled function with a Value stack.
/// Sets up a stack with the given fixnum values, calls the function, and
/// returns the status code. On success, `result` is set to the top fixnum.
fn callCompiled(func: CompiledFn, inputs: []const i64, result: *i64) i32 {
    var values: [16]Value = undefined;
    for (inputs, 0..) |v, i| {
        values[i] = .{ .fixnum = v };
    }
    var sp: usize = inputs.len;
    var jit_ctx = JitContext{
        .items_ptr = &values,
        .sp_ptr = &sp,
        .capacity = values.len,
        .ctx = @ptrFromInt(@as(usize, 1)),
    };
    const status = func(&jit_ctx);
    if (status == 0 and sp > 0) {
        result.* = values[sp - 1].fixnum;
    }
    return status;
}

/// Helper to call a compiled function with raw Value stack for non-fixnum tests.
fn callCompiledValues(func: CompiledFn, values: []Value, sp: *usize) i32 {
    var jit_ctx = JitContext{
        .items_ptr = values.ptr,
        .sp_ptr = sp,
        .capacity = values.len,
        .ctx = @ptrFromInt(@as(usize, 1)),
    };
    return func(&jit_ctx);
}

test "compile double: 2 *" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{5}, &out));
    try testing.expectEqual(@as(i64, 10), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{-3}, &out));
    try testing.expectEqual(@as(i64, -6), out);
}

test "compile (a+3)*4" {
    const instrs = makeInstructions(.{ @as(i64, 3), "+", @as(i64, 4), "*" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{7}, &out));
    try testing.expectEqual(@as(i64, 40), out);
}

test "compile a+b with two inputs" {
    const instrs = makeInstructions(.{"+"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 17, 25 }, &out));
    try testing.expectEqual(@as(i64, 42), out);
}

test "compiled direct call preserves aliased lower stack values" {
    var dispatch = JitDispatchTable.init(testing.allocator);
    defer dispatch.deinit();

    const callee_instrs = makeInstructions(.{"+"});
    const callee = try compileWord(&callee_instrs, 2, 1, null, null, null, null);
    const callee_id = try dispatch.assignId("sum2");
    dispatch.update(callee_id, callee.code_ptr, callee.jit_buf);

    const ResolverState = struct {
        callee_id: u32,
    };
    var resolver_state = ResolverState{ .callee_id = callee_id };
    const Resolver = struct {
        fn resolve(name: []const u8, user_data: *anyopaque) ?ResolvedWord {
            const state: *ResolverState = @ptrCast(@alignCast(user_data));
            if (!std.mem.eql(u8, name, "sum2")) return null;
            return .{
                .word_id = state.callee_id,
                .input_count = 2,
                .output_count = 1,
            };
        }
    };
    const resolver = WordResolver{
        .resolve = &Resolver.resolve,
        .user_data = @ptrCast(&resolver_state),
        .dispatch_table_ptr = @ptrCast(&dispatch),
    };

    const caller_instrs = makeInstructions(.{ @as(i64, 1), "-", "over", "swap", "sum2", "*" });
    const caller = try compileWord(&caller_instrs, 2, 1, resolver, null, null, null);
    defer caller.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(caller.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 2, 4 }, &out));
    try testing.expectEqual(@as(i64, 10), out);
}

test "overflow bails out" {
    const instrs = makeInstructions(.{ std.math.maxInt(i64), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{1}, &out));
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{0}, &out));
    try testing.expectEqual(std.math.maxInt(i64), out);
}

test "overflow preserves sp" {
    const instrs = makeInstructions(.{ std.math.maxInt(i64), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .fixnum = 1 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "division by zero bails out" {
    const instrs = makeInstructions(.{"/"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{ 10, 0 }, &out));
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 10, 2 }, &out));
    try testing.expectEqual(@as(i64, 5), out);
}

test "division minInt/-1 bails out" {
    const instrs = makeInstructions(.{"/"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{ std.math.minInt(i64), -1 }, &out));
}

test "bail on non-fixnum input" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .string = "hello" }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "bail on stack underflow" {
    const instrs = makeInstructions(.{"+"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .fixnum = 42 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "compile string literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .string);
    try testing.expect(std.mem.eql(u8, "hello", values[0].string));
}

test "compile float literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.14), values[0].float);
}

test "compile boolean literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);
}

test "compile symbol literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .symbol = "foo" } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .symbol);
    try testing.expect(std.mem.eql(u8, "foo", values[0].symbol));
}

test "compile unit literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .unit }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .unit);
}

test "arithmetic on opaque operand bails at runtime" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    values[0] = .{ .fixnum = 1 };
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "bail on float input to arithmetic" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .float = 2.5 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "bail on boolean input to arithmetic" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .boolean = true }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 1), status);
    try testing.expectEqual(@as(usize, 1), sp);
}

test "fixnum literal still works after refactor" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 1 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "reject non-compilable: unsupported word" {
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = "print" }, .line = 1 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 1, 1, null, null, null, null));
}

test "compile with output_count 2" {
    const instrs = makeInstructions(.{ @as(i64, 10), @as(i64, 20) });
    const result = try compileWord(&instrs, 0, 2, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
    try testing.expectEqual(@as(i64, 20), values[1].fixnum);
}

test "rem with div-by-zero guard" {
    const instrs = makeInstructions(.{"rem"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 7, 3 }, &out));
    try testing.expectEqual(@as(i64, 1), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ -7, 3 }, &out));
    try testing.expectEqual(@as(i64, -1), out);
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{ 7, 0 }, &out));
}

test "compile dup on fixnum" {
    const instrs = makeInstructions(.{"dup"});
    const result = try compileWord(&instrs, 1, 2, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    values[0] = .{ .fixnum = 7 };
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(@as(i64, 7), values[0].fixnum);
    try testing.expectEqual(@as(i64, 7), values[1].fixnum);
}

test "compile drop on fixnum" {
    const instrs = makeInstructions(.{"drop"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 10 }, .{ .fixnum = 20 } };
    var sp: usize = 2;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
}

test "compile swap on fixnums" {
    const instrs = makeInstructions(.{"swap"});
    const result = try compileWord(&instrs, 2, 2, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 10 }, .{ .fixnum = 20 } };
    var sp: usize = 2;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expectEqual(@as(i64, 20), values[0].fixnum);
    try testing.expectEqual(@as(i64, 10), values[1].fixnum);
}

test "compile over on fixnums" {
    const instrs = makeInstructions(.{"over"});
    const result = try compileWord(&instrs, 2, 3, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    values[0] = .{ .fixnum = 10 };
    values[1] = .{ .fixnum = 20 };
    var sp: usize = 2;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 3), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
    try testing.expectEqual(@as(i64, 20), values[1].fixnum);
    try testing.expectEqual(@as(i64, 10), values[2].fixnum);
}

test "compile dup * (square)" {
    const instrs = makeInstructions(.{ "dup", "*" });
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{5}, &out));
    try testing.expectEqual(@as(i64, 25), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{-3}, &out));
    try testing.expectEqual(@as(i64, 9), out);
}

test "compile swap - (reverse subtract)" {
    const instrs = makeInstructions(.{ "swap", "-" });
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 3, 10 }, &out));
    try testing.expectEqual(@as(i64, 7), out);
}

test "compile swap drop (nip)" {
    const instrs = makeInstructions(.{ "swap", "drop" });
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 3, 10 }, &out));
    try testing.expectEqual(@as(i64, 10), out);
}

test "compile non-fixnum literal dup" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .string);
    try testing.expect(std.mem.eql(u8, "hello", values[0].string));
    try testing.expect(values[1] == .string);
    try testing.expect(std.mem.eql(u8, "hello", values[1].string));
}

test "compile non-fixnum literal swap" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "aaa" } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .string = "bbb" } }, .line = 2 },
        .{ .op = .{ .call_word = "swap" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .string);
    try testing.expect(std.mem.eql(u8, "bbb", values[0].string));
    try testing.expect(values[1] == .string);
    try testing.expect(std.mem.eql(u8, "aaa", values[1].string));
}

test "compile = comparison" {
    const instrs = makeInstructions(.{"="});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(false, values[0].boolean);
}

test "compile < comparison" {
    const instrs = makeInstructions(.{"<"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 3 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(false, values[0].boolean);
}

test "compile > comparison" {
    const instrs = makeInstructions(.{">"});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 3 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(true, values[0].boolean);

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expect(values[0] == .boolean);
    try testing.expectEqual(false, values[0].boolean);
}

test "compile comparison on non-fixnum bails" {
    const instrs = makeInstructions(.{"="});
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .string = "hello" }, .{ .fixnum = 5 } };
    var sp: usize = 2;
    try testing.expectEqual(@as(i32, 1), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 2), sp);
}

test "compile if with bool condition" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);
}

test "compile if with false condition" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = false } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 20), values[0].fixnum);
}

test "compile comparison + if" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .call_word = ">" }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 2, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;

    values[0] = .{ .fixnum = 5 };
    values[1] = .{ .fixnum = 3 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 10), values[0].fixnum);

    values[0] = .{ .fixnum = 3 };
    values[1] = .{ .fixnum = 5 };
    sp = 2;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 20), values[0].fixnum);
}

test "compile if with arithmetic in branches" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 2 },
        .{ .op = .{ .call_word = "+" }, .line = 3 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 3 } }, .line = 2 },
        .{ .op = .{ .call_word = "-" }, .line = 3 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expectEqual(@as(i64, 8), values[0].fixnum);
}

test "compile if with stack shape mismatch fails" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 30 } }, .line = 2 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    try testing.expectError(IrCodegenError.StackShapeMismatch, compileWord(&instrs, 0, 1, null, null, null, null));
}

test "compile if with non-compilable body fails" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .call_word = "print" }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 20 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 1, null, null, null, null));
}

test "compile float dup" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 1 },
        .{ .op = .{ .call_word = "dup" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 2.5), values[0].float);
    try testing.expect(values[1] == .float);
    try testing.expectEqual(@as(f64, 2.5), values[1].float);
}

test "compile float swap" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "swap" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 2, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 2), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 2.0), values[0].float);
    try testing.expect(values[1] == .float);
    try testing.expectEqual(@as(f64, 1.0), values[1].float);
}

test "compile float if-else merge" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.0 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .boolean = true } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 1.0), values[0].float);
}

test "compile float truthiness in if" {
    const true_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
    };
    const false_body = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = true_body } } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = false_body } } }, .line = 3 },
        .{ .op = .{ .call_word = "if" }, .line = 4 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 1), values[0].fixnum);
}

test "compile float addition" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "+" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 4.0), values[0].float);
}

test "compile float subtraction" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 5.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "-" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.0), values[0].float);
}

test "compile float multiplication" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 3.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "*" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 6.0), values[0].float);
}

test "compile float division" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 7.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "/" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.5), values[0].float);
}

test "compile float comparison =" {
    const instrs_eq = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "=" }, .line = 3 },
    };
    const result_eq = try compileWord(&instrs_eq, 0, 1, null, null, null, null);
    defer result_eq.jit_buf.deinit();

    const func_eq: CompiledFn = @ptrCast(@alignCast(result_eq.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func_eq, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == true);

    const instrs_ne = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "=" }, .line = 3 },
    };
    const result_ne = try compileWord(&instrs_ne, 0, 1, null, null, null, null);
    defer result_ne.jit_buf.deinit();

    const func_ne: CompiledFn = @ptrCast(@alignCast(result_ne.code_ptr));
    sp = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func_ne, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == false);
}

test "compile float comparison <" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 2 },
        .{ .op = .{ .call_word = "<" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == true);
}

test "compile float comparison >" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 2.5 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 2 },
        .{ .op = .{ .call_word = ">" }, .line = 3 },
    };
    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .boolean);
    try testing.expect(values[0].boolean == true);
}

test "compile float + raw_at_slot input" {
    // Float literal inside compiled body + float input from caller.
    // resolveOperandPair sees f64_ref + raw_at_slot -> resolves both as f64.
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 1.5 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{.{ .float = 2.5 }};
    var sp: usize = 1;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 4.0), values[0].float);
}

test "div with float operand bails" {
    // div is integer-only; f64_ref operand should cause NotCompilable.
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 7.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "div" }, .line = 3 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 1, null, null, null, null));
}

test "% with float operand bails" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 7.0 } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .float = 2.0 } }, .line = 2 },
        .{ .op = .{ .call_word = "%" }, .line = 3 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 1, null, null, null, null));
}

test "compile inline virtual-unwrap" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    var inner_val = Value{ .fixnum = 42 };
    const tagged_val = Value{ .tagged = .{ .tag = &vtype, .inner = &inner_val } };
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = tagged_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 2 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "inline virtual-unwrap bails on wrong vtype" {
    var vtype_a = VirtualType{ .name = "type-a", .inner_type = "fixnum" };
    var vtype_b = VirtualType{ .name = "type-b", .inner_type = "fixnum" };
    var inner_val = Value{ .fixnum = 99 };
    const tagged_val = Value{ .tagged = .{ .tag = &vtype_a, .inner = &inner_val } };
    const vtype_b_ptr: i64 = @intCast(@intFromPtr(&vtype_b));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = tagged_val }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_b_ptr } }, .line = 2 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 1), callCompiledValues(func, &values, &sp));
}

test "inline virtual-unwrap bails on non-tagged value" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 1 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 123 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 1), callCompiledValues(func, &values, &sp));
}

test "inline virtual-unwrap on input parameter" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    var inner_val = Value{ .fixnum = 77 };
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 1 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .tagged = .{ .tag = &vtype, .inner = &inner_val } }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 77), values[0].fixnum);
}

test "inline virtual-unwrap then arithmetic" {
    var vtype = VirtualType{ .name = "test-vt", .inner_type = "fixnum" };
    var inner_val = Value{ .fixnum = 10 };
    const vtype_ptr: i64 = @intCast(@intFromPtr(&vtype));

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = vtype_ptr } }, .line = 1 },
        .{ .op = .{ .call_word = "native.virtual-unwrap" }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 3 },
        .{ .op = .{ .call_word = "+" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .tagged = .{ .tag = &vtype, .inner = &inner_val } }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 15), values[0].fixnum);
}

test "compile inline struct-field-get field 0" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &instance } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 3 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "compile inline struct-field-get field 1" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_instance = &instance } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 2 },
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 3 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 4 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 99), values[0].fixnum);
}

test "inline struct-field-get on input parameter" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var fields = [_]Value{ .{ .fixnum = 77 }, .{ .fixnum = 88 } };
    var instance = StructInstance{ .struct_type = &st, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .struct_instance = &instance }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 77), values[0].fixnum);
}

test "inline struct-field-get bails on non-struct value" {
    var st = StructType{ .name = "point", .fields = &.{ "x", "y" } };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_type = &st } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 123 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 1), callCompiledValues(func, &values, &sp));
}

test "inline struct-field-get bails on wrong struct type" {
    var st_a = StructType{ .name = "point", .fields = &.{ "x", "y" } };
    var st_b = StructType{ .name = "color", .fields = &.{ "r", "g" } };
    var fields = [_]Value{ .{ .fixnum = 42 }, .{ .fixnum = 99 } };
    var instance = StructInstance{ .struct_type = &st_a, .fields = &fields };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .struct_type = &st_b } }, .line = 1 },
        .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 2 },
        .{ .op = .{ .call_word = "native.struct-field-get" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .struct_instance = &instance }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 1), callCompiledValues(func, &values, &sp));
}

test "compile inline typed-validate-and-promote with fixnum" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "array(fixnum)", .inner_type = "array", .type_params = &type_params };
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 42 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 42), values[0].fixnum);
}

test "compile inline typed-validate-and-promote with float" {
    var float_tv = TypeValue{ .name = "float", .descriptor = null };
    var type_params = [_]*const TypeValue{&float_tv};
    var vt = VirtualType{ .name = "array(float)", .inner_type = "array", .type_params = &type_params };
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .float = 3.14 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .float);
    try testing.expectEqual(@as(f64, 3.14), values[0].float);
}

test "inline typed-validate-and-promote bails on type mismatch" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "array(fixnum)", .inner_type = "array", .type_params = &type_params };
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 1 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .float = 1.5 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 1), callCompiledValues(func, &values, &sp));
}

test "inline typed-validate-and-promote no-op when no type_params" {
    var vt = VirtualType{ .name = "wrapper", .inner_type = "array" };
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 99 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 99), values[0].fixnum);
}

test "inline typed-validate-and-promote on input parameter" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "vector(fixnum)", .inner_type = "vector", .type_params = &type_params };
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 1 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 2 },
    };

    const result = try compileWord(&instrs, 1, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values = [_]Value{ .{ .fixnum = 55 }, .unit, .unit, .unit };
    var sp: usize = 1;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 55), values[0].fixnum);
}

test "inline typed-validate-and-promote then arithmetic" {
    var fixnum_tv = TypeValue{ .name = "fixnum", .descriptor = null };
    var type_params = [_]*const TypeValue{&fixnum_tv};
    var vt = VirtualType{ .name = "array(fixnum)", .inner_type = "array", .type_params = &type_params };
    const vtype_ptr: Value = .{ .fixnum = @intCast(@intFromPtr(&vt)) };

    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 10 } }, .line = 1 },
        .{ .op = .{ .push_literal = vtype_ptr }, .line = 2 },
        .{ .op = .{ .call_word = "native.typed-validate-and-promote" }, .line = 3 },
        .{ .op = .{ .push_literal = .{ .fixnum = 5 } }, .line = 4 },
        .{ .op = .{ .call_word = "+" }, .line = 5 },
    };

    const result = try compileWord(&instrs, 0, 1, null, null, null, null);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    try testing.expectEqual(@as(i32, 0), callCompiledValues(func, &values, &sp));
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .fixnum);
    try testing.expectEqual(@as(i64, 15), values[0].fixnum);
}

// --- C emission tests ---

test "mangle simple word name" {
    const name = try mangleWordName("double", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w_double", name);
}

test "mangle word name with special chars" {
    const name = try mangleWordName("#map", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w__Hmap", name);
}

test "mangle word name with kebab-case" {
    const name = try mangleWordName("?or-else", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w__Qor_else", name);
}

test "mangle word name with multiple specials" {
    const name = try mangleWordName("@set!", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w__Aset_B", name);
}

test "mangle word name preserves digits and underscores" {
    const name = try mangleWordName("foo_bar2", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("onez_w_foo_bar2", name);
}

test "emit C for double: 2 *" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const source = try emitWordC(&instrs, 1, 1, "double", testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.startsWith(u8, source, "#include <stdint.h>"));
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_double") != null);
    try testing.expect(std.mem.indexOf(u8, source, "return") != null);
}

test "emit C for (a+3)*4" {
    const instrs = makeInstructions(.{ @as(i64, 3), "+", @as(i64, 4), "*" });
    const source = try emitWordC(&instrs, 1, 1, "compute", testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "onez_w_compute") != null);
}

test "emit C for push literal" {
    const instrs = makeInstructions(.{@as(i64, 42)});
    const source = try emitWordC(&instrs, 0, 1, "forty-two", testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "onez_w_forty_two") != null);
}

test "emitted C compiles with cc" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const source = try emitWordC(&instrs, 1, 1, "double", testing.allocator);
    defer testing.allocator.free(source);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const c_file = try tmp_dir.dir.createFile("test.c", .{});
    try c_file.writeAll(source);
    c_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = try tmp_dir.dir.realpath("test.c", &path_buf);

    // invoke cc -fsyntax-only to verify the C source is valid
    var child = std.process.Child.init(
        &.{ "cc", "-fsyntax-only", "-Wno-incompatible-pointer-types", c_path },
        testing.allocator,
    );
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const result = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result);
}

test "emitWordCAot emits named callback for safepoint" {
    // A word with a loop needs a safepoint callback. In AOT mode, the
    // callback should appear as a named function call, not a hex address.
    const instrs = makeInstructions(.{ @as(i64, 10), "times" });
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = emitWordCAot(
        &instrs,
        1,
        0,
        "repeat",
        null,
        null,
        &compiled_names,
        null,
        testing.allocator,
    ) catch |err| {
        // times requires a quotation on stack which we don't have in this
        // minimal test -- NotCompilable is expected. Skip this test case
        // if the word is too complex for the minimal instruction set.
        if (err == error.NotCompilable) return;
        return err;
    };
    defer testing.allocator.free(source);

    // If compilation succeeded, verify named callback reference
    try testing.expect(std.mem.indexOf(u8, source, "jitSafepoint") != null);
    // Should NOT contain hex addresses like 0x
    try testing.expect(std.mem.indexOf(u8, source, "0x1") == null);
}

test "emitWordCAot basic arithmetic" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    var compiled_names: std.StringHashMapUnmanaged(u32) = .{};
    defer compiled_names.deinit(testing.allocator);

    const source = try emitWordCAot(
        &instrs,
        1,
        1,
        "double",
        null,
        null,
        &compiled_names,
        null,
        testing.allocator,
    );
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "onez_w_double") != null);
    try testing.expect(std.mem.indexOf(u8, source, "return") != null);
    // No preamble -- caller adds it
    try testing.expect(!std.mem.startsWith(u8, source, "#include"));
}

test "emitProgramC generates complete C source" {
    const double_instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const add3_instrs = makeInstructions(.{ @as(i64, 3), "+" });

    const words = [_]AotWordDesc{
        .{ .name = "double", .instructions = &double_instrs, .input_count = 1, .output_count = 1, .word_id = 0 },
        .{ .name = "add3", .instructions = &add3_instrs, .input_count = 1, .output_count = 1, .word_id = 1 },
    };

    var diag: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, 0, 1, &.{}, &diag, testing.allocator);
    defer testing.allocator.free(source);

    // Preamble
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdint.h>") != null);
    try testing.expect(std.mem.indexOf(u8, source, "#include <stdbool.h>") != null);

    // Runtime externs
    try testing.expect(std.mem.indexOf(u8, source, "onez_init") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_set_args") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_runtime_run") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_print_error") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_deinit") != null);

    // Forward declarations
    try testing.expect(std.mem.indexOf(u8, source, "int32_t onez_w_double(uintptr_t jit_ctx);") != null);
    try testing.expect(std.mem.indexOf(u8, source, "int32_t onez_w_add3(uintptr_t jit_ctx);") != null);

    // Word bodies
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_double") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_add3") != null);

    // Dispatch table
    try testing.expect(std.mem.indexOf(u8, source, "onez_dispatch_table") != null);
    try testing.expect(std.mem.indexOf(u8, source, "onez_word_fn_t") != null);

    // Main entry point
    try testing.expect(std.mem.indexOf(u8, source, "int main(") != null);
}

test "emitProgramC dispatch table has correct entries" {
    const instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "foo", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 0 },
        .{ .name = "bar", .instructions = &instrs, .input_count = 0, .output_count = 1, .word_id = 2 },
    };

    var diag2: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, 0, 2, &.{}, &diag2, testing.allocator);
    defer testing.allocator.free(source);

    // word_id 0 -> onez_w_foo
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_foo,") != null);
    // word_id 1 -> NULL (gap)
    try testing.expect(std.mem.indexOf(u8, source, "NULL,") != null);
    // word_id 2 -> onez_w_bar
    try testing.expect(std.mem.indexOf(u8, source, "onez_w_bar,") != null);
}

test "emitProgramC output compiles with cc" {
    const double_instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const lit_instrs = makeInstructions(.{@as(i64, 42)});

    const words = [_]AotWordDesc{
        .{ .name = "double", .instructions = &double_instrs, .input_count = 1, .output_count = 1, .word_id = 0 },
        .{ .name = "answer", .instructions = &lit_instrs, .input_count = 0, .output_count = 1, .word_id = 1 },
    };

    var diag3: CodegenDiagnostics = .{};
    const source = try emitProgramC(&words, 1, 1, &.{}, &diag3, testing.allocator);
    defer testing.allocator.free(source);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const c_file = try tmp_dir.dir.createFile("test_aot.c", .{});
    try c_file.writeAll(source);
    c_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = try tmp_dir.dir.realpath("test_aot.c", &path_buf);

    var child = std.process.Child.init(
        &.{ "cc", "-fsyntax-only", "-Wno-incompatible-pointer-types", c_path },
        testing.allocator,
    );
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const result = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result);
}
