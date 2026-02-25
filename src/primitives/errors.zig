const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const ErrorObject = value_mod.ErrorObject;
const StackFrame = value_mod.StackFrame;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;

pub const primitives = [_]Primitive{
    .{ .name = "recover", .stack_effect = "try-quot recover-quot: ( error -- ) --", .func = nativeRecover },
    .{ .name = "cleanup", .stack_effect = "body-quot cleanup-quot --", .func = nativeCleanup },
    .{ .name = "rethrow", .stack_effect = "error --", .func = nativeRethrow },
};

/// recover ( try-quot recover-quot -- ) - Execute try quotation; if error,
/// execute recover quotation with error on stack
pub fn nativeRecover(ctx: *Context) anyerror!void {
    // Note: Parameter effects are validated statically by validateParameterEffects
    // before this function is called, so we just pop the quotations here.
    const recover_quot = try popQuotation(ctx);
    const try_quot = try popQuotation(ctx);

    // Execute try quotation with error-catching
    ctx.executeQuotationWithFrame(try_quot) catch |err| {
        const alloc = ctx.quotationAllocator();
        var stack_trace: ?[]const StackFrame = null;

        if (ctx.error_details.items.len > 0) {
            const frames = alloc.alloc(StackFrame, ctx.error_details.items.len) catch null;
            if (frames) |f| {
                for (ctx.error_details.items, 0..) |detail, i| {
                    f[i] = .{
                        .word_name = detail.word_name orelse detail.message,
                        .source = detail.source,
                        .line = detail.line,
                    };
                }
                stack_trace = f;
            }
        }

        const error_obj = ErrorObject{
            .error_type = @errorName(err),
            .message = @errorName(err),
            .stack_trace = stack_trace,
        };
        try ctx.stack.push(.{ .error_value = error_obj });

        // Clear error details after capturing, and execute recovery
        ctx.clearExecutionDetails();
        try ctx.executeQuotationWithFrame(recover_quot);
        return;
    };
}

/// cleanup ( body-quot cleanup-quot -- ) - Execute body, always run cleanup,
/// then re-throw any error from body
pub fn nativeCleanup(ctx: *Context) anyerror!void {
    const cleanup_quot = try popQuotation(ctx);
    const body_quot = try popQuotation(ctx);

    // Execute body quotation, capturing any error
    const body_result = ctx.executeQuotationWithFrame(body_quot);

    // Always execute cleanup quotation, even if body failed
    // If cleanup also fails, we ignore that error and prioritize the body error
    ctx.executeQuotationWithFrame(cleanup_quot) catch {
        // Cleanup error is suppressed; body error takes priority
    };

    // Re-throw original error if body failed
    try body_result;
}

/// rethrow ( error -- ) - Re-raise an error value as an actual error
pub fn nativeRethrow(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .error_value => |err_obj| {
            // Restore the error details from the ErrorObject's stack trace
            if (err_obj.stack_trace) |trace| {
                // Clear any existing error details and restore from the error object
                ctx.error_details.clearRetainingCapacity();
                for (trace) |frame| {
                    ctx.error_details.append(ctx.allocator, .{
                        .error_type = err_obj.error_type,
                        .message = err_obj.message,
                        .source = frame.source,
                        .line = frame.line,
                        .word_name = frame.word_name,
                    }) catch {};
                }
            }
            return error.RethrowError;
        },
        else => return error.TypeError,
    }
}
