const std = @import("std");

const c = @cImport({
    @cInclude("ir.h");
    @cInclude("ir_builder.h");
});

pub const ir = c;

pub const IrError = error{
    CompilationFailed,
};

pub const JitBuffer = struct {
    code: *anyopaque,
    size: usize,

    pub fn deinit(self: JitBuffer) void {
        _ = ir.ir_mem_unmap(self.code, self.size);
    }
};

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
