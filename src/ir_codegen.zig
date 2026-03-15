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

/// Compile a word's instruction sequence into native code via the ir JIT.
/// The compiled function has the signature:
///   int32_t fn(i64 arg0, [i64 arg1, ...] i64 *result) -> 0=success, 1=bail
/// Only supports push_literal of fixnums and call_word of supported arithmetic ops.
pub fn compileWord(
    instructions: []const Instruction,
    input_count: u8,
    output_count: u8,
) IrCodegenError!CompiledWord {
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

    // Parameters: input_count i64 params + 1 pointer param for result
    var params: [8]c.ir_ref = undefined;
    if (input_count > 0) params[0] = c._ir_PARAM(&ctx, c.IR_I64, "a", 1);
    if (input_count > 1) params[1] = c._ir_PARAM(&ctx, c.IR_I64, "b", 2);
    if (input_count > 2) params[2] = c._ir_PARAM(&ctx, c.IR_I64, "c", 3);
    if (input_count > 3) params[3] = c._ir_PARAM(&ctx, c.IR_I64, "d", 4);
    if (input_count > 4) params[4] = c._ir_PARAM(&ctx, c.IR_I64, "e", 5);
    if (input_count > 5) params[5] = c._ir_PARAM(&ctx, c.IR_I64, "f", 6);
    if (input_count > 6) params[6] = c._ir_PARAM(&ctx, c.IR_I64, "g", 7);
    if (input_count > 7) params[7] = c._ir_PARAM(&ctx, c.IR_I64, "h", 8);
    const result_ptr_param = c._ir_PARAM(&ctx, c.IR_ADDR, "result_ptr", @intCast(input_count + 1));

    // Symbolic stack of ir refs
    var stack: [64]c.ir_ref = undefined;
    var sp: usize = 0;

    // Push input params onto symbolic stack (first param is deepest)
    for (0..input_count) |i| {
        stack[sp] = params[i];
        sp += 1;
    }

    // Constant for bail return
    const bail_status = c.ir_const_i32(&ctx, 1);
    const ok_status = c.ir_const_i32(&ctx, 0);

    // Process each instruction
    for (instructions) |instr| {
        switch (instr.op) {
            .push_literal => |val| {
                stack[sp] = c.ir_const_i64(&ctx, val.fixnum);
                sp += 1;
            },
            .call_word => |name| {
                if (std.mem.eql(u8, name, "abs")) {
                    // Unary: abs
                    if (sp < 1) return IrCodegenError.StackUnderflow;
                    sp -= 1;
                    const a = stack[sp];

                    // Check for minInt(i64): bail since abs(minInt) overflows
                    const min_val = c.ir_const_i64(&ctx, std.math.minInt(i64));
                    const is_min = c.ir_fold2(&ctx, c.IR_OPT(c.IR_EQ, c.IR_BOOL), a, min_val);
                    const if_min = c._ir_IF(&ctx, is_min);
                    c._ir_IF_TRUE_cold(&ctx, if_min);
                    c._ir_RETURN(&ctx, bail_status);
                    c._ir_IF_FALSE(&ctx, if_min);

                    // abs(a) = a >= 0 ? a : -a
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
                    // Binary op
                    if (sp < 2) return IrCodegenError.StackUnderflow;
                    sp -= 2;
                    const a = stack[sp];
                    const b = stack[sp + 1];

                    if (std.mem.eql(u8, name, "+")) {
                        const result = emitOverflowCheckedBinary(&ctx, c.IR_ADD_OV, a, b, bail_status);
                        stack[sp] = result;
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "-")) {
                        const result = emitOverflowCheckedBinary(&ctx, c.IR_SUB_OV, a, b, bail_status);
                        stack[sp] = result;
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "*")) {
                        const result = emitOverflowCheckedBinary(&ctx, c.IR_MUL_OV, a, b, bail_status);
                        stack[sp] = result;
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "div")) {
                        const result = emitDivision(&ctx, a, b, bail_status);
                        stack[sp] = result;
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "rem")) {
                        const result = emitRemainder(&ctx, a, b, bail_status);
                        stack[sp] = result;
                        sp += 1;
                    } else if (std.mem.eql(u8, name, "%")) {
                        const result = emitEuclideanMod(&ctx, a, b, bail_status);
                        stack[sp] = result;
                        sp += 1;
                    }
                }
            },
        }
    }

    // Final stack should have exactly 1 value
    if (sp != 1) return IrCodegenError.StackShapeMismatch;

    // Store result and return success
    c._ir_STORE(&ctx, result_ptr_param, stack[0]);
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

/// Execute a JIT-compiled word. Pops inputs from the 1z stack, calls the
/// compiled function, and pushes the result. Returns .bail if any input is
/// not a fixnum or the compiled function signals overflow/error, in which
/// case the stack is restored so the interpreter can re-execute the word.
pub fn executeCompiled(ctx: *Context, word_id: u32) ExecResult {
    const entry = ctx.jit_dispatch.get(word_id) orelse return .bail;
    const code_ptr = entry.code_ptr orelse return .bail;
    const n_in = entry.input_count;

    // Pop input_count values, type-check fixnum
    var raw_inputs: [8]i64 = undefined;
    var saved_values: [8]Value = undefined;
    var i: usize = n_in;
    while (i > 0) {
        i -= 1;
        const val = ctx.stack.pop() catch return .bail;
        saved_values[i] = val;
        if (val != .fixnum) {
            // Re-push all popped values
            var j: usize = i;
            while (j < n_in) : (j += 1) {
                ctx.stack.push(saved_values[j]) catch return .bail;
            }
            return .bail;
        }
        raw_inputs[i] = val.fixnum;
    }

    var result: i64 = undefined;
    const status: i32 = switch (n_in) {
        1 => blk: {
            const func: *const fn (i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(code_ptr));
            break :blk func(raw_inputs[0], &result);
        },
        2 => blk: {
            const func: *const fn (i64, i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(code_ptr));
            break :blk func(raw_inputs[0], raw_inputs[1], &result);
        },
        3 => blk: {
            const func: *const fn (i64, i64, i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(code_ptr));
            break :blk func(raw_inputs[0], raw_inputs[1], raw_inputs[2], &result);
        },
        4 => blk: {
            const func: *const fn (i64, i64, i64, i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(code_ptr));
            break :blk func(raw_inputs[0], raw_inputs[1], raw_inputs[2], raw_inputs[3], &result);
        },
        else => {
            // Re-push values for unsupported arity
            for (0..n_in) |j| {
                ctx.stack.push(saved_values[j]) catch return .bail;
            }
            return .bail;
        },
    };

    if (status != 0) {
        // Bail: re-push all values for interpreter fallback
        for (0..n_in) |j| {
            ctx.stack.push(saved_values[j]) catch return .bail;
        }
        return .bail;
    }

    ctx.stack.push(.{ .fixnum = result }) catch return .bail;
    return .ok;
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

test "compile double: 2 *" {
    const instrs = makeInstructions(.{ @as(i64, 2), "*" });
    const result = try compileWord(&instrs, 1, 1);
    defer result.jit_buf.deinit();

    const func: *const fn (i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), func(5, &out));
    try testing.expectEqual(@as(i64, 10), out);
    try testing.expectEqual(@as(i32, 0), func(-3, &out));
    try testing.expectEqual(@as(i64, -6), out);
}

test "compile (a+3)*4" {
    const instrs = makeInstructions(.{ @as(i64, 3), "+", @as(i64, 4), "*" });
    const result = try compileWord(&instrs, 1, 1);
    defer result.jit_buf.deinit();

    const func: *const fn (i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), func(7, &out));
    try testing.expectEqual(@as(i64, 40), out);
}

test "compile a+b with two inputs" {
    const instrs = makeInstructions(.{"+"});
    const result = try compileWord(&instrs, 2, 1);
    defer result.jit_buf.deinit();

    const func: *const fn (i64, i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), func(17, 25, &out));
    try testing.expectEqual(@as(i64, 42), out);
}

test "overflow bails out" {
    const instrs = makeInstructions(.{ std.math.maxInt(i64), "+" });
    const result = try compileWord(&instrs, 1, 1);
    defer result.jit_buf.deinit();

    const func: *const fn (i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), func(1, &out));
    // No overflow for small values
    try testing.expectEqual(@as(i32, 0), func(0, &out));
    try testing.expectEqual(std.math.maxInt(i64), out);
}

test "division by zero bails out" {
    const instrs = makeInstructions(.{"/"});
    const result = try compileWord(&instrs, 2, 1);
    defer result.jit_buf.deinit();

    const func: *const fn (i64, i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), func(10, 0, &out));
    try testing.expectEqual(@as(i32, 0), func(10, 2, &out));
    try testing.expectEqual(@as(i64, 5), out);
}

test "division minInt/-1 bails out" {
    const instrs = makeInstructions(.{"/"});
    const result = try compileWord(&instrs, 2, 1);
    defer result.jit_buf.deinit();

    const func: *const fn (i64, i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 1), func(std.math.minInt(i64), -1, &out));
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

    const func: *const fn (i64, i64, *i64) callconv(.c) i32 = @ptrCast(@alignCast(result.code_ptr));
    var out: i64 = undefined;
    try testing.expectEqual(@as(i32, 0), func(7, 3, &out));
    try testing.expectEqual(@as(i64, 1), out);
    try testing.expectEqual(@as(i32, 0), func(-7, 3, &out));
    try testing.expectEqual(@as(i64, -1), out);
    try testing.expectEqual(@as(i32, 1), func(7, 0, &out));
}
