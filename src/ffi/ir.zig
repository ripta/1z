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
        ir.ir_discard_code(self.code, self.size);
    }
};

/// Compiles a trivial function that adds two i64 values and returns the result.
/// The returned JitBuffer owns the compiled code and must be cleaned up via deinit.
pub fn compileAdd() IrError!struct { func: *const fn (i64, i64) callconv(.C) i64, buf: JitBuffer } {
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
