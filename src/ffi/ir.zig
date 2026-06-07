const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

// Freestanding builds skip the ir/ir_builder C headers (the JIT backend is
// not part of the bare-metal artifact). The stub keeps the module's surface
// well-typed without dragging in the unavailable C headers; the JIT entry
// points are unreachable on freestanding because nothing constructs an
// ir_ctx in that build.
const c = if (is_freestanding) struct {
    pub const ir_ctx = extern struct {
        unnamed_0: extern struct {
            data: ?*anyopaque = null,
        } = .{},
        ret_type: c_int = 0,
    };
    pub const FILE = opaque {};
    pub const SEEK_END: c_int = 2;
    pub const SEEK_SET: c_int = 0;
    pub const IR_FUNCTION: c_int = 0;
    pub const IR_OPT_FOLDING: c_int = 0;
    pub const IR_CONSTS_LIMIT_MIN: c_int = 0;
    pub const IR_INSNS_LIMIT_MIN: c_int = 0;
    pub const IR_I64: c_int = 0;
    pub const IR_I32: c_int = 0;
    pub const IR_BOOL: c_int = 0;
    pub const IR_ADDR: c_int = 0;
    pub const IR_ADD: c_int = 0;
    pub const IR_NE: c_int = 0;
    pub const IR_UNUSED: c_int = 0;
    pub fn IR_OPT(op: c_int, ty: c_int) c_int {
        _ = op;
        _ = ty;
        return 0;
    }
    pub fn ir_init(_: *ir_ctx, _: c_int, _: c_int, _: c_int) void {}
    pub fn ir_free(_: *ir_ctx) void {}
    pub fn _ir_START(_: *ir_ctx) void {}
    pub fn _ir_PARAM(_: *ir_ctx, _: c_int, _: [*:0]const u8, _: c_int) c_int {
        return 0;
    }
    pub fn _ir_LOAD(_: *ir_ctx, _: c_int, _: c_int) c_int {
        return 0;
    }
    pub fn ir_const_addr(_: *ir_ctx, _: usize) c_int {
        return 0;
    }
    pub fn _ir_RETURN(_: *ir_ctx, _: c_int) void {}
    pub fn _ir_IF(_: *ir_ctx, _: c_int) c_int {
        return 0;
    }
    pub fn _ir_IF_TRUE_cold(_: *ir_ctx, _: c_int) void {}
    pub fn _ir_IF_FALSE(_: *ir_ctx, _: c_int) void {}
    pub fn ir_fold2(_: *ir_ctx, _: c_int, _: c_int, _: c_int) c_int {
        return 0;
    }
    pub fn ir_const_i32(_: *ir_ctx, _: c_int) c_int {
        return 0;
    }
    pub fn ir_build_def_use_lists(_: *ir_ctx) void {}
    pub fn ir_build_cfg(_: *ir_ctx) c_int {
        return 0;
    }
    pub fn ir_assign_virtual_registers(_: *ir_ctx) c_int {
        return 0;
    }
    pub fn ir_compute_dessa_moves(_: *ir_ctx) c_int {
        return 0;
    }
    pub fn ir_emit_c(_: *ir_ctx, _: [*:0]const u8, _: *FILE) c_int {
        return 0;
    }
    pub fn ir_jit_compile(_: *ir_ctx, _: c_int, _: *usize) ?*anyopaque {
        return null;
    }
    pub fn ir_mem_unmap(_: *anyopaque, _: usize) c_int {
        return 0;
    }
    pub fn tmpfile() ?*FILE {
        return null;
    }
    pub fn fclose(_: *FILE) c_int {
        return 0;
    }
    pub fn fseek(_: *FILE, _: c_long, _: c_int) c_int {
        return 0;
    }
    pub fn ftell(_: *FILE) c_long {
        return 0;
    }
    pub fn fread(_: [*]u8, _: usize, _: usize, _: *FILE) usize {
        return 0;
    }
} else @cImport({
    @cInclude("ir.h");
    @cInclude("ir_builder.h");
});

pub const ir = c;

pub const IrError = error{
    CompilationFailed,
    EmitFailed,
};

pub const JitBuffer = struct {
    code: *anyopaque,
    size: usize,

    pub fn deinit(self: JitBuffer) void {
        _ = ir.ir_mem_unmap(self.code, self.size);
    }
};

/// Run the minimum IR optimization passes needed for C emission and emit
/// the IR context as a C function. Returns the C source as an owned slice.
///
/// `source_lines` is an optional opaque pointer to an `IrCSourceLines`
/// (defined in ir_codegen.zig). When non-null it is installed on
/// `ctx.data` immediately before the C emission call so the patched
/// `ir_emit_c.c` can emit `#line` directives at control-flow
/// boundaries. The magic-tag check inside the patch keeps the call
/// safe for callers that pass null.
pub fn emitC(
    ctx: *c.ir_ctx,
    name: [*:0]const u8,
    allocator: std.mem.Allocator,
    source_lines: ?*const anyopaque,
) (IrError || std.mem.Allocator.Error)![]u8 {
    // XXX(ripta): Run minimum passes: def-use lists, CFG, virtual register assignment.
    //             ir_match NOT needed?
    //             ir_assign_virtual_registers falls back to the slow path when ctx->rules is null
    c.ir_build_def_use_lists(ctx);
    if (c.ir_build_cfg(ctx) == 0) return IrError.EmitFailed;
    if (c.ir_assign_virtual_registers(ctx) == 0) return IrError.EmitFailed;
    if (c.ir_compute_dessa_moves(ctx) == 0) return IrError.EmitFailed;

    if (source_lines) |sl| {
        ctx.unnamed_0.data = @constCast(sl);
    }

    const file: *c.FILE = c.tmpfile() orelse return IrError.EmitFailed;
    defer _ = c.fclose(file);

    if (c.ir_emit_c(ctx, name, file) == 0) return IrError.EmitFailed;

    _ = c.fseek(file, 0, c.SEEK_END);
    const size: usize = @intCast(c.ftell(file));
    _ = c.fseek(file, 0, c.SEEK_SET);

    const buf = try allocator.alloc(u8, size);
    const read = c.fread(buf.ptr, 1, size, file);
    if (read < size) {
        allocator.free(buf);
        return IrError.EmitFailed;
    }
    return buf;
}

/// Compiles a trivial function that adds two i64 values and returns the result.
/// The returned JitBuffer owns the compiled code and must be cleaned up via deinit.
pub fn compileAdd() IrError!struct { func: *const fn (i64, i64) callconv(.c) i64, buf: JitBuffer } {
    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION | c.IR_OPT_FOLDING, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    c._ir_START(&ctx);
    const a = c._ir_PARAM(&ctx, c.IR_I64, "a", 1);
    const b = c._ir_PARAM(&ctx, c.IR_I64, "b", 2);
    const sum = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_I64), a, b);
    c._ir_RETURN(&ctx, sum);

    var size: usize = 0;
    const code: ?*anyopaque = c.ir_jit_compile(&ctx, 2, &size);
    if (code) |ptr| {
        return .{
            .func = @ptrCast(@alignCast(ptr)),
            .buf = .{ .code = ptr, .size = size },
        };
    }
    return IrError.CompilationFailed;
}

test "compile and execute trivial add via ir" {
    const result = try compileAdd();
    defer result.buf.deinit();

    const add = result.func;
    try std.testing.expectEqual(@as(i64, 42), add(17, 25));
    try std.testing.expectEqual(@as(i64, 0), add(-5, 5));
    try std.testing.expectEqual(@as(i64, -10), add(-3, -7));
}

test "multiple independent compilations coexist" {
    const r1 = try compileAdd();
    defer r1.buf.deinit();
    const r2 = try compileAdd();
    defer r2.buf.deinit();

    // Both compiled functions work independently
    try std.testing.expectEqual(@as(i64, 10), r1.func(3, 7));
    try std.testing.expectEqual(@as(i64, 20), r2.func(8, 12));

    // Cross-verify they don't interfere
    try std.testing.expectEqual(@as(i64, 100), r1.func(50, 50));
    try std.testing.expectEqual(@as(i64, -1), r2.func(0, -1));
}

test "cleanup and reuse lifecycle" {
    // First cycle: compile, execute, discard
    {
        const r = try compileAdd();
        try std.testing.expectEqual(@as(i64, 5), r.func(2, 3));
        r.buf.deinit();
    }

    // Second cycle: compile again, proving the lifecycle is repeatable
    {
        const r = try compileAdd();
        defer r.buf.deinit();
        try std.testing.expectEqual(@as(i64, 7), r.func(3, 4));
    }

    // Third cycle: one more round to confirm stability
    {
        const r = try compileAdd();
        defer r.buf.deinit();
        try std.testing.expectEqual(@as(i64, -1), r.func(1, -2));
    }
}

test "i64 boundary values" {
    const r = try compileAdd();
    defer r.buf.deinit();
    const add = r.func;

    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);

    // max + 0 and min + 0
    try std.testing.expectEqual(max, add(max, 0));
    try std.testing.expectEqual(min, add(min, 0));

    // Overflow wraps: max + 1 wraps to min (two's complement)
    try std.testing.expectEqual(min, add(max, 1));

    // Underflow wraps: min - 1 wraps to max
    try std.testing.expectEqual(max, add(min, -1));

    // max + max wraps to -2
    try std.testing.expectEqual(@as(i64, -2), add(max, max));
}

test "emit C for trivial add function" {
    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);

    c._ir_START(&ctx);
    const a = c._ir_PARAM(&ctx, c.IR_I64, "a", 1);
    const b = c._ir_PARAM(&ctx, c.IR_I64, "b", 2);
    const sum = c.ir_fold2(&ctx, c.IR_OPT(c.IR_ADD, c.IR_I64), a, b);
    c._ir_RETURN(&ctx, sum);

    const source = try emitC(&ctx, "test_add", std.testing.allocator, null);
    defer std.testing.allocator.free(source);

    // Verify the output contains expected C constructs
    try std.testing.expect(std.mem.indexOf(u8, source, "test_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "int64_t") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return") != null);
}

test "emit C for terminal callback diamond" {
    var ctx: c.ir_ctx = undefined;
    c.ir_init(&ctx, c.IR_FUNCTION, c.IR_CONSTS_LIMIT_MIN, c.IR_INSNS_LIMIT_MIN);
    defer c.ir_free(&ctx);
    ctx.ret_type = c.IR_I32;

    c._ir_START(&ctx);
    const call_result = c._ir_PARAM(&ctx, c.IR_I32, "call_result", 1);
    const zero = c.ir_const_i32(&ctx, 0);
    const propagate = c.ir_const_i32(&ctx, 2);
    const call_failed = c.ir_fold2(&ctx, c.IR_OPT(c.IR_NE, c.IR_BOOL), call_result, zero);
    const if_bail = c._ir_IF(&ctx, call_failed);
    c._ir_IF_TRUE_cold(&ctx, if_bail);
    c._ir_RETURN(&ctx, call_result);
    c._ir_IF_FALSE(&ctx, if_bail);
    c._ir_RETURN(&ctx, propagate);

    const source = try emitC(&ctx, "test_terminal_callback", std.testing.allocator, null);
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "test_terminal_callback") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return") != null);
}
