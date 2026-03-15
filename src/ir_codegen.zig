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

    var payload_offset: usize = 0;
    var tag_offset: usize = 0;
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
        initialized = true;
    }
};

/// The compiled function signature: operates directly on the per-task stack.
///   items_ptr: base of the Value array
///   sp:        pointer to current stack depth (read and written)
///   capacity:  current array capacity for bounds checking
///   returns:   0 = success, 1 = bail (stack unchanged)
pub const CompiledFn = *const fn ([*]Value, *usize, usize) callconv(.c) i32;

/// Compile a word's instruction sequence into native code via the ir JIT.
/// The compiled function operates directly on the per-task Value stack.
/// Only supports push_literal of fixnums and call_word of supported arithmetic ops.
pub fn compileWord(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
) IrCodegenError!CompiledWord {
    ValueLayout.ensureInit();

    if (output_count != 1) return IrCodegenError.NotCompilable;
    if (input_count > 8) return IrCodegenError.NotCompilable;

    // Validate compilability
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                if (val != .fixnum) return IrCodegenError.NotCompilable;
            },
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
    const fixnum_tag_const = c.ir_const_u8(&ctx, ValueLayout.fixnum_tag);

    // Phase 1: Check all fixnum tags before any writes
    var elem_addrs: [8]c.ir_ref = undefined;
    for (0..input_count) |i| {
        const n_const = c.ir_const_addr(&ctx, input_count - i);
        const idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, n_const);
        const byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), idx, value_size_const);
        const elem_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, byte_offset);
        elem_addrs[i] = elem_addr;

        const tag_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addr, tag_offset_const);
        const tag_val = c._ir_LOAD(&ctx, ValueLayout.ir_tag_type, tag_addr);
        const tag_mismatch = c.ir_fold2(&ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), tag_val, fixnum_tag_const);
        const if_mismatch = c._ir_IF(&ctx, tag_mismatch);
        c._ir_IF_TRUE_cold(&ctx, if_mismatch);
        c._ir_RETURN(&ctx, bail_status);
        c._ir_IF_FALSE(&ctx, if_mismatch);
    }

    // Phase 2: Load i64 payloads onto symbolic stack
    var stack: [64]c.ir_ref = undefined;
    var sp: usize = 0;
    for (0..input_count) |i| {
        const payload_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), elem_addrs[i], payload_offset_const);
        stack[sp] = c._ir_LOAD(&ctx, c.IR_I64, payload_addr);
        sp += 1;
    }

    // Phase 3: Process each instruction
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                stack[sp] = c.ir_const_i64(&ctx, val.fixnum);
                sp += 1;
            },
            .call_word => |name| {
                if (std.mem.eql(u8, name, "abs")) {
                    if (sp < 1) return IrCodegenError.StackUnderflow;
                    sp -= 1;
                    const a = stack[sp];

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
                    stack[sp] = result;
                    sp += 1;
                } else {
                    if (sp < 2) return IrCodegenError.StackUnderflow;
                    sp -= 2;
                    const a = stack[sp];
                    const b = stack[sp + 1];

                    if (std.mem.eql(u8, name, "+")) {
                        stack[sp] = emitOverflowCheckedBinary(&ctx, c.IR_ADD_OV, a, b, bail_status);
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "-")) {
                        stack[sp] = emitOverflowCheckedBinary(&ctx, c.IR_SUB_OV, a, b, bail_status);
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "*")) {
                        stack[sp] = emitOverflowCheckedBinary(&ctx, c.IR_MUL_OV, a, b, bail_status);
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "div")) {
                        stack[sp] = emitDivision(&ctx, a, b, bail_status);
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "rem")) {
                        stack[sp] = emitRemainder(&ctx, a, b, bail_status);
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "%")) {
                        stack[sp] = emitEuclideanMod(&ctx, a, b, bail_status);
                        sp += 1;
                    }
                }
            },
        }
    }

    // Final stack should have exactly 1 value
    if (sp != 1) return IrCodegenError.StackShapeMismatch;

    // Phase 4: Write result as fixnum Value at items[sp_val - input_count]
    const result_n_const = c.ir_const_addr(&ctx, input_count);
    const result_idx = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, result_n_const);
    const result_byte_offset = c.ir_fold2(&ctx, c.IR_OPT(c.IR_MUL, c.IR_ADDR), result_idx, value_size_const);
    const result_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), items_ptr, result_byte_offset);

    const result_tag_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), result_addr, tag_offset_const);
    c._ir_STORE(&ctx, result_tag_addr, fixnum_tag_const);

    const result_payload_addr = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_ADDR), result_addr, payload_offset_const);
    c._ir_STORE(&ctx, result_payload_addr, stack[0]);

    // Update sp: sp_val - input_count + output_count
    const sp_delta = c.ir_const_addr(&ctx, input_count - output_count);
    const new_sp = c.ir_fold2(&ctx, c.IR_OPT(c.IR_SUB, c.IR_ADDR), sp_val, sp_delta);
    c._ir_STORE(&ctx, sp_ptr, new_sp);

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

test "reject non-compilable: string literal" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .string = "hello" } }, .line = 1 },
    };
    try testing.expectError(IrCodegenError.NotCompilable, compileWord(&instrs, 0, 1));
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
