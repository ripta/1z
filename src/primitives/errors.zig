const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const ErrorObject = value_mod.ErrorObject;
const StackFrame = value_mod.StackFrame;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popQuotation = helpers.popQuotation;

/// Convert a PascalCase error name to kebab-case at comptime.
/// E.g., "StackUnderflow" -> "stack-underflow", "IOError" -> "io-error"
pub fn pascalToKebab(comptime name: []const u8) []const u8 {
    comptime {
        if (name.len == 0) return "";
        var result: [name.len * 2]u8 = undefined;
        var out_len: usize = 0;

        var i: usize = 0;
        while (i < name.len) {
            const c = name[i];
            if (c >= 'A' and c <= 'Z') {
                const next_is_lower = (i + 1 < name.len) and (name[i + 1] >= 'a' and name[i + 1] <= 'z');

                if (i > 0) {
                    const prev_is_upper = (name[i - 1] >= 'A' and name[i - 1] <= 'Z');
                    if (prev_is_upper and next_is_lower) {
                        // End of acronym before a new word: "IOError" -> insert dash before 'E'
                        result[out_len] = '-';
                        out_len += 1;
                    } else if (!prev_is_upper) {
                        // Normal transition from lowercase to uppercase
                        result[out_len] = '-';
                        out_len += 1;
                    }
                }

                result[out_len] = c - 'A' + 'a';
                out_len += 1;
            } else {
                result[out_len] = c;
                out_len += 1;
            }
            i += 1;
        }

        const final = result[0..out_len];
        return final[0..final.len];
    }
}

/// Runtime version: convert a PascalCase Zig error name to a 1z error symbol.
/// Writes into a caller-provided buffer.
pub fn pascalToKebabRuntime(name: []const u8, buf: []u8) []const u8 {
    if (name.len == 0) return "";
    var out_len: usize = 0;

    for (name, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            const next_is_lower = (i + 1 < name.len) and (name[i + 1] >= 'a' and name[i + 1] <= 'z');

            if (i > 0) {
                const prev_is_upper = (name[i - 1] >= 'A' and name[i - 1] <= 'Z');
                if (prev_is_upper and next_is_lower) {
                    if (out_len < buf.len) {
                        buf[out_len] = '-';
                        out_len += 1;
                    }
                } else if (!prev_is_upper) {
                    if (out_len < buf.len) {
                        buf[out_len] = '-';
                        out_len += 1;
                    }
                }
            }

            if (out_len < buf.len) {
                buf[out_len] = c - 'A' + 'a';
                out_len += 1;
            }
        } else {
            if (out_len < buf.len) {
                buf[out_len] = c;
                out_len += 1;
            }
        }
    }

    return buf[0..out_len];
}

pub const primitives = [_]Primitive{
    .{ .name = "recover", .stack_effect = "try-quot recover-quot: ( error -- ..a ) --", .doc = "Execute try quotation; if error, run recover quotation with error on stack.", .func = nativeRecover },
    .{ .name = "cleanup", .stack_effect = "body-quot cleanup-quot --", .doc = "Execute body, always run cleanup, then re-throw any error from body.", .func = nativeCleanup },
    .{ .name = "rethrow", .stack_effect = "error --", .doc = "Re-raise an error value as an actual error.", .func = nativeRethrow },
    .{ .name = "make-error", .stack_effect = "data message type -- error", .doc = "Construct an error object from data, message, and type.", .func = nativeMakeError },
    .{ .name = "throw", .stack_effect = "error --", .doc = "Raise an error object as an actual error.", .func = nativeThrow },
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
        // Check if this is a user-thrown error with a stashed ErrorObject
        if (err == error.UserThrown) {
            if (ctx.thrown_error) |thrown| {
                var error_obj = thrown;
                ctx.thrown_error = null;

                // Capture stack trace from error_details if not already present
                if (error_obj.stack_trace == null and ctx.error_details.items.len > 0) {
                    const alloc = ctx.quotationAllocator();
                    const frames = alloc.alloc(StackFrame, ctx.error_details.items.len) catch null;
                    if (frames) |f| {
                        for (ctx.error_details.items, 0..) |detail, i| {
                            f[i] = .{
                                .word_name = detail.word_name orelse detail.message,
                                .source = detail.source,
                                .line = detail.line,
                            };
                        }
                        error_obj.stack_trace = f;
                    }
                }

                try ctx.stack.push(.{ .error_value = error_obj });
                ctx.clearExecutionDetails();
                try ctx.executeQuotationWithFrame(recover_quot);
                return;
            }
        }

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

        var kebab_buf: [128]u8 = undefined;
        const kebab_name = pascalToKebabRuntime(@errorName(err), &kebab_buf);
        const duped_name = alloc.dupe(u8, kebab_name) catch @errorName(err);
        const error_obj = ErrorObject{
            .error_type = duped_name,
            .message = duped_name,
            .data = null,
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

    // Shield the cleanup quotation from re-cancellation so it can yield,
    // sleep, or do I/O without being interrupted by a pending cancellation.
    const task = if (ctx.scheduler) |sched| sched.current_task else null;
    const was_unwinding = if (task) |t| t.cancellation_phase == .unwinding else false;
    if (was_unwinding) task.?.cancellation_phase = .shielded;

    // Always execute cleanup quotation, even if body failed
    // If cleanup also fails, we ignore that error and prioritize the body error
    ctx.executeQuotationWithFrame(cleanup_quot) catch {
        // Cleanup error is suppressed; body error takes priority
    };

    if (was_unwinding) task.?.cancellation_phase = .unwinding;

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
            return error.UserRethrown;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "error", val);
            return error.TypeMismatch;
        },
    }
}

/// make-error ( data message type -- error ) - Construct an error object.
/// data: any value or f (arbitrary associated data)
/// message: string or f (human-readable message)
/// type: string or symbol (error type name)
fn nativeMakeError(ctx: *Context) anyerror!void {
    const type_val = try ctx.stack.pop();
    const message_val = try ctx.stack.pop();
    const data_val = try ctx.stack.pop();

    // Extract error type from string or symbol
    const error_type = switch (type_val) {
        .string => |s| s,
        .symbol => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string or symbol", type_val);
            return error.TypeMismatch;
        },
    };

    // Extract message from string or f (false = no message)
    const message = switch (message_val) {
        .string => |s| s,
        .boolean => |b| if (!b) error_type else {
            helpers.setTypeMismatchError(ctx, "string or f", message_val);
            return error.TypeMismatch;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "string or f", message_val);
            return error.TypeMismatch;
        },
    };

    // Data can be any value; f means no data
    const data: ?*const Value = switch (data_val) {
        .boolean => |b| if (!b) null else blk: {
            const alloc = ctx.quotationAllocator();
            const ptr = alloc.create(Value) catch return error.OutOfMemory;
            ptr.* = data_val;
            break :blk ptr;
        },
        else => blk: {
            const alloc = ctx.quotationAllocator();
            const ptr = alloc.create(Value) catch return error.OutOfMemory;
            ptr.* = data_val;
            break :blk ptr;
        },
    };

    const error_obj = ErrorObject{
        .error_type = error_type,
        .message = message,
        .data = data,
    };
    try ctx.stack.push(.{ .error_value = error_obj });
}

/// throw ( error -- ) - Raise an error object as an actual error.
/// Only accepts error values. The error object is stashed on the context
/// and recovered by `recover` with its original type, message, and data intact.
fn nativeThrow(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .error_value => |err_obj| {
            ctx.thrown_error = err_obj;
            return error.UserThrown;
        },
        else => {
            helpers.setErrorHint(ctx, "use `data message type make-error` to create an error value");
            helpers.setTypeMismatchError(ctx, "error", val);
            return error.TypeMismatch;
        },
    }
}
