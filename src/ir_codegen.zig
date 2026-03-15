const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;

const ir_mod = @import("ffi/ir.zig");
const JitBuffer = ir_mod.JitBuffer;
const c = ir_mod.ir;

pub const IrCodegenError = error{
    NotCompilable,
    CompilationFailed,
    StackUnderflow,
    StackShapeMismatch,
};

pub const CompiledWord = struct {
    code_ptr: *const anyopaque,
    jit_buf: JitBuffer,
};

const supported_binary_ops = [_][]const u8{ "+", "-", "*", "/", "div", "rem", "%" };
const supported_unary_ops = [_][]const u8{"abs"};

fn isSupportedOp(name: []const u8) bool {
    for (supported_binary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    for (supported_unary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn isBinaryOp(name: []const u8) bool {
    for (supported_binary_ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

/// Layout of Value for use in generated IR code, determined at runtime
/// since Zig unions don't expose field offsets at comptime.
const ValueLayout = struct {
    const TagType = std.meta.Tag(Value);
    const value_size: usize = @sizeOf(Value);
    const tag_size: usize = @sizeOf(TagType);
    const fixnum_tag: u8 = @intFromEnum(@as(TagType, .fixnum));

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
            .hash, .vector, .byte_array, .set, .mutable_map, .stream, .resource, .parameter, .module, .marker, .struct_type, .struct_instance, .benchmark_report, .task, .channel, .iterator, .type_val => .ptr,
            .string, .symbol, .array, .doc_string, .template => .slice,
            .tagged => .dual_ptr,
            .bignum, .quotation, .stack_effect, .error_value => .inline_,
        };
    }

    var payload_offset: usize = 0;
    var tag_offset: usize = 0;
    var slice_len_offset: usize = 0;
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

/// Symbolic stack entry: either a raw i64 payload usable in arithmetic,
/// or an opaque Value already written to the physical stack.
const StackEntry = union(enum) {
    i64_ref: c.ir_ref,
    raw_value,
};

/// The compiled function signature: operates directly on the per-task stack.
///   items_ptr: base of the Value array
///   sp:        pointer to current stack depth (read and written)
///   capacity:  current array capacity for bounds checking
///   returns:   0 = success, 1 = bail (stack unchanged)
pub const CompiledFn = *const fn ([*]Value, *usize, usize) callconv(.c) i32;

/// Compile a word's instruction sequence into native code via the ir JIT.
/// The compiled function operates directly on the per-task Value stack.
/// Supports push_literal of any Value variant and call_word of supported
/// arithmetic ops (arithmetic still requires fixnum operands at runtime).
pub fn compileWord(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
) IrCodegenError!CompiledWord {
    ValueLayout.ensureInit();

    if (output_count != 1) return IrCodegenError.NotCompilable;
    if (input_count > 8) return IrCodegenError.NotCompilable;

    // Validate compilability: only supported call_words are checked here.
    // Any Value variant is accepted for push_literal.
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => {},
            .call_word => |name| {
                if (!isSupportedOp(name)) return IrCodegenError.NotCompilable;
            },
        }
    }

    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION | c.IR_OPT_FOLDING, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    c._ir_START(&ctx);

    // Parameters: items_ptr, sp_ptr, capacity
    const items_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "items_ptr", 1);
    const sp_ptr = c._ir_PARAM(&ctx, c.IR_ADDR, "sp_ptr", 2);
    const capacity_param = c._ir_PARAM(&ctx, c.IR_ADDR, "capacity", 3);
    _ = capacity_param;

    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);

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

    // Precompute the base address for output writes:
    // base_addr = items_ptr + (sp_val - input_count) * value_size
    const input_count_const = c.ir_const_addr(&ctx, input_count);
    const base_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, input_count_const);
    const base_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), base_idx, value_size_const);
    const base_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, base_byte_offset);

    // Check all fixnum tags on inputs before any writes
    var elem_addrs: [8]c.ir_ref = undefined;
    for (0..input_count) |i| {
        const n_const = c.ir_const_addr(&ctx, input_count - i);
        const idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, n_const);
        const byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), idx, value_size_const);
        const elem_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, byte_offset);
        elem_addrs[i] = elem_addr;

        emitTagCheck(&ctx, elem_addr, fixnum_tag_const, tag_offset_const, bail_status);
    }

    // Load i64 payloads from inputs onto symbolic stack
    var stack: [64]StackEntry = undefined;
    var sp: usize = 0;
    for (0..input_count) |i| {
        stack[sp] = .{ .i64_ref = emitUnboxI64(&ctx, elem_addrs[i], payload_offset_const) };
        sp += 1;
    }

    // Process each instruction
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (val == .fixnum) {
                    stack[sp] = .{ .i64_ref = c.ir_const_i64(&ctx, val.fixnum) };
                    sp += 1;
                } else {
                    // Write the full Value bytes to the destination stack slot
                    const sp_byte_offset = c.ir_const_addr(&ctx, sp * ValueLayout.value_size);
                    const dest_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), base_addr, sp_byte_offset);
                    emitPushValue(&ctx, &val, dest_addr);
                    stack[sp] = .raw_value;
                    sp += 1;
                }
            },
            .call_word => |name| {
                if (std.mem.eql(u8, name, "abs")) {
                    if (sp < 1) return IrCodegenError.StackUnderflow;
                    sp -= 1;
                    const a = switch (stack[sp]) {
                        .i64_ref => |ref| ref,
                        .raw_value => return IrCodegenError.NotCompilable,
                    };

                    const min_val = c.ir_const_i64(&ctx, std.math.minInt(i64));
                    const is_min = c.ir_fold2(&ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), a, min_val);
                    const if_min = c._ir_IF(&ctx, is_min);
                    c._ir_IF_TRUE_cold(&ctx, if_min);
                    c._ir_RETURN(&ctx, bail_status);
                    c._ir_IF_FALSE(&ctx, if_min);

                    const zero = c.ir_const_i64(&ctx, 0);
                    const is_neg = c.ir_fold2(&ctx, c.IR_OPT(c.IR_LT, c.IR_BOOL), a, zero);
                    const neg_a = c.ir_fold1(&ctx, c.IR_OPT(c.IR_NEG, c.IR_I64), a);
                    const if_neg = c._ir_IF(&ctx, is_neg);
                    c._ir_IF_TRUE(&ctx, if_neg);
                    const end_true = c._ir_END(&ctx);
                    c._ir_IF_FALSE(&ctx, if_neg);
                    const end_false = c._ir_END(&ctx);
                    c._ir_MERGE_2(&ctx, end_true, end_false);
                    const result = c._ir_PHI_2(&ctx, c.IR_I64, neg_a, a);
                    stack[sp] = .{ .i64_ref = result };
                    sp += 1;
                } else {
                    if (sp < 2) return IrCodegenError.StackUnderflow;
                    sp -= 2;
                    const a = switch (stack[sp]) {
                        .i64_ref => |ref| ref,
                        .raw_value => return IrCodegenError.NotCompilable,
                    };
                    const b = switch (stack[sp + 1]) {
                        .i64_ref => |ref| ref,
                        .raw_value => return IrCodegenError.NotCompilable,
                    };

                    if (std.mem.eql(u8, name, "+")) {
                        stack[sp] = .{ .i64_ref = emitOverflowCheckedBinary(&ctx, c.IR_ADD_OV, a, b, bail_status) };
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "-")) {
                        stack[sp] = .{ .i64_ref = emitOverflowCheckedBinary(&ctx, c.IR_SUB_OV, a, b, bail_status) };
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "*")) {
                        stack[sp] = .{ .i64_ref = emitOverflowCheckedBinary(&ctx, c.IR_MUL_OV, a, b, bail_status) };
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "div")) {
                        stack[sp] = .{ .i64_ref = emitDivision(&ctx, a, b, bail_status) };
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "rem")) {
                        stack[sp] = .{ .i64_ref = emitRemainder(&ctx, a, b, bail_status) };
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "%")) {
                        stack[sp] = .{ .i64_ref = emitEuclideanMod(&ctx, a, b, bail_status) };
                        sp += 1;
                    }
                }
            },
        }
    }

    // Final stack should have exactly 1 value
    if (sp != 1) return IrCodegenError.StackShapeMismatch;

    switch (stack[0]) {
        .i64_ref => |result_ref| {
            // Box the i64 result as a fixnum Value at base_addr
            emitBoxPayload(&ctx, base_addr, tag_offset_const, payload_offset_const, fixnum_tag_const, result_ref);
        },
        .raw_value => {
            // The Value was already written to base_addr by emitPushValue
        },
    }

    // Update sp: new_sp = sp_val - input_count + output_count
    if (input_count > output_count) {
        const sp_delta = c.ir_const_addr(&ctx, input_count - output_count);
        const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, sp_delta);
        c._ir_STORE(&ctx, sp_ptr, new_sp);
    } else if (input_count < output_count) {
        const sp_delta = c.ir_const_addr(&ctx, output_count - input_count);
        const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), sp_val, sp_delta);
        c._ir_STORE(&ctx, sp_ptr, new_sp);
    }
    // else input_count == output_count: sp unchanged

    c._ir_RETURN(&ctx, ok_status);

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

    const if_adjust = c._ir_IF(ctx, needs_adjust);
    c._ir_IF_TRUE(ctx, if_adjust);
    const adjusted = c.ir_fold2(ctx, c.IR_OPT(c.IR_ADD, c.IR_I64), rem_val, b);
    const end_true = c._ir_END(ctx);
    c._ir_IF_FALSE(ctx, if_adjust);
    const end_false = c._ir_END(ctx);
    c._ir_MERGE_2(ctx, end_true, end_false);

    return c._ir_PHI_2(ctx, c.IR_I64, adjusted, rem_val);
}

// =============================================================================
// Trampoline
// =============================================================================

const Context = @import("context.zig").Context;
const JitDispatchTable = @import("jit_dispatch.zig").JitDispatchTable;

/// Result of attempting compiled execution.
pub const ExecResult = enum { ok, bail };

/// Execute a JIT-compiled word. The compiled function operates directly on
/// the per-task Value stack: it reads inputs, checks fixnum tags, performs
/// arithmetic, writes the result, and adjusts the stack pointer. Returns
/// .bail if the compiled function signals a type mismatch or overflow, in
/// which case the stack is unchanged.
pub fn executeCompiled(ctx: *Context, word_id: u32) ExecResult {
    const entry = ctx.jit_dispatch.get(word_id) orelse return .bail;
    const code_ptr = entry.code_ptr orelse return .bail;

    const func: CompiledFn = @ptrCast(@alignCast(code_ptr));
    const status = func(
        ctx.stack.items.items.ptr,
        &ctx.stack.items.items.len,
        ctx.stack.items.capacity,
    );

    return if (status == 0) .ok else .bail;
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
    const status = func(&values, &sp, values.len);
    if (status == 0 and sp > 0) {
        result.* = values[sp - 1].fixnum;
    }
    return status;
}

/// Helper to call a compiled function with raw Value stack for non-fixnum tests.
fn callCompiledValues(func: CompiledFn, values: []Value, sp: *usize) i32 {
    return func(values.ptr, sp, values.len);
}

test "compile double: 2 *" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const result = try compileWord(&instrs, 1, 1);
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
    const result = try compileWord(&instrs, 1, 1);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{7}, &out));
    try testing.expectEqual(@as(i64, 40), out);
}

test "compile a+b with two inputs" {
    const instrs = makeInstructions(.{"+"});
    const result = try compileWord(&instrs, 2, 1);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 17, 25 }, &out));
    try testing.expectEqual(@as(i64, 42), out);
}

test "overflow bails out" {
    const instrs = makeInstructions(.{ std.math.maxInt(i64), "+" });
    const result = try compileWord(&instrs, 1, 1);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{1}, &out));
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{0}, &out));
    try testing.expectEqual(std.math.maxInt(i64), out);
}

test "overflow preserves sp" {
    const instrs = makeInstructions(.{ std.math.maxInt(i64), "+" });
    const result = try compileWord(&instrs, 1, 1);
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
    const result = try compileWord(&instrs, 2, 1);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{ 10, 0 }, &out));
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 10, 2 }, &out));
    try testing.expectEqual(@as(i64, 5), out);
}

test "division minInt/-1 bails out" {
    const instrs = makeInstructions(.{"/"});
    const result = try compileWord(&instrs, 2, 1);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{ std.math.minInt(i64), -1 }, &out));
}

test "bail on non-fixnum input" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1);
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
    const result = try compileWord(&instrs, 2, 1);
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
    const result = try compileWord(&instrs, 0, 1);
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
    const result = try compileWord(&instrs, 0, 1);
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
    const result = try compileWord(&instrs, 0, 1);
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
    const result = try compileWord(&instrs, 0, 1);
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
    const result = try compileWord(&instrs, 0, 1);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var values: [4]Value = undefined;
    var sp: usize = 0;
    const status = callCompiledValues(func, &values, &sp);
    try testing.expectEqual(@as(i32, 0), status);
    try testing.expectEqual(@as(usize, 1), sp);
    try testing.expect(values[0] == .unit);
}

test "arithmetic on opaque operand is not compilable" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 1, 1));
}

test "bail on float input to arithmetic" {
    const instrs = makeInstructions(.{ @as(i64, 1), "+" });
    const result = try compileWord(&instrs, 1, 1);
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
    const result = try compileWord(&instrs, 1, 1);
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
    const result = try compileWord(&instrs, 0, 1);
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
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 1, 1));
}

test "reject output_count != 1" {
    const instrs = makeInstructions(.{@as(i64, 1)});
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 2));
}

test "rem with div-by-zero guard" {
    const instrs = makeInstructions(.{"rem"});
    const result = try compileWord(&instrs, 2, 1);
    defer result.jit_buf.deinit();

    const func: CompiledFn = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ 7, 3 }, &out));
    try testing.expectEqual(@as(i64, 1), out);
    try testing.expectEqual(@as(i32, 0), callCompiled(func, &.{ -7, 3 }, &out));
    try testing.expectEqual(@as(i64, -1), out);
    try testing.expectEqual(@as(i32, 1), callCompiled(func, &.{ 7, 0 }, &out));
}
