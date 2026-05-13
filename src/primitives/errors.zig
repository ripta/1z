const std = @import("std");

const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const TypeRegistryFrame = context_mod.TypeRegistryFrame;

const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const ErrorObject = value_mod.ErrorObject;
const StackFrame = value_mod.StackFrame;

const stack_effect_mod = @import("../stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;

const helpers = @import("helpers.zig");
const popQuotation = helpers.popQuotation;

const Marker = value_mod.Marker;
const Primitive = @import("types.zig").Primitive;
const markers_mod = @import("markers.zig");

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
    .{ .name = "rethrow", .stack_effect = "error --", .doc = "Re-raise an error value as an actual error.", .func = nativeRethrow, .markers = &.{@constCast(&markers_mod.never_returns_marker)} },
    .{ .name = "make-error", .stack_effect = "data message type -- error", .doc = "Construct an error object from data, message, and type.", .func = nativeMakeError },
    .{ .name = "throw", .stack_effect = "error --", .doc = "Raise an error object as an actual error.", .func = nativeThrow, .markers = &.{@constCast(&markers_mod.never_returns_marker)} },
    .{ .name = "with-isolation", .stack_effect = "quot --", .doc = "Execute quotation with isolated type registry, dispatch tables, and protocol obligations. Only stack effects survive.", .func = nativeWithIsolation },
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
            if (ctx.thrown_error) |thrown_ptr| {
                ctx.thrown_error = null;

                // Capture stack trace from error_details if not already present
                if (thrown_ptr.stack_trace == null and ctx.error_details.items.len > 0) {
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
                        thrown_ptr.stack_trace = f;
                    }
                }

                try ctx.stack.push(.{ .error_value = thrown_ptr });
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
        const error_ptr = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
            .error_type = duped_name,
            .message = duped_name,
            .data = null,
            .stack_trace = stack_trace,
        });
        try ctx.stack.push(.{ .error_value = error_ptr });

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

    const error_ptr = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = try ctx.quotationAllocator().dupe(u8, error_type),
        .message = try ctx.quotationAllocator().dupe(u8, message),
        .data = data,
    });
    try ctx.stack.push(.{ .error_value = error_ptr });
}

/// throw ( error -- ) - Raise an error object as an actual error.
/// Only accepts error values. The error object is stashed on the context
/// and recovered by `recover` with its original type, message, and data intact.
fn nativeThrow(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    switch (val) {
        .error_value => |err_obj| {
            // Clone the box so the stashed pointer is exclusive to the
            // throw path. The stack-resident original (from `dup` before
            // throw, or survival above the unwind frame) keeps its own
            // box, which is freed at context teardown.
            ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), err_obj.*);
            return error.UserThrown;
        },
        else => {
            helpers.setErrorHint(ctx, "use `data message type make-error` to create an error value");
            helpers.setTypeMismatchError(ctx, "error", val);
            return error.TypeMismatch;
        },
    }
}

/// Check a single value for references to types registered in the isolation
/// frame, which is the topmost type registry frame.
///
/// Returns the dangling type name if found, null otherwise. Depth-limited to avoid unbounded recursion.
fn findDanglingIsolatedType(val: Value, isolation_frame: *const TypeRegistryFrame, depth: usize) ?[]const u8 {
    if (depth > 16) return null;

    switch (val) {
        .tagged => |t| {
            if (t.tag.parent_type) |pt| {
                if (isolation_frame.type_descriptors.get(pt.name) != null) return pt.name;
            }

            if (isolation_frame.type_descriptors.get(t.tag.name) != null) return t.tag.name;
            return findDanglingIsolatedType(t.inner.*, isolation_frame, depth + 1);
        },
        .array => |items| {
            for (items) |item| {
                if (findDanglingIsolatedType(item, isolation_frame, depth + 1)) |name| return name;
            }
            return null;
        },
        .hash => |h| {
            var it = h.iterator();
            while (it.next()) |entry| {
                if (findDanglingIsolatedType(entry.value_ptr.*, isolation_frame, depth + 1)) |name| return name;
            }
            return null;
        },
        .vector => |v| {
            for (v.items) |item| {
                if (findDanglingIsolatedType(item, isolation_frame, depth + 1)) |name| return name;
            }
            return null;
        },
        .set => |s| {
            for (s.keys()) |key| {
                if (findDanglingIsolatedType(key, isolation_frame, depth + 1)) |name| return name;
            }
            return null;
        },
        .mutable_map => |m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                if (findDanglingIsolatedType(entry.value_ptr.*, isolation_frame, depth + 1)) |name| return name;
            }
            return null;
        },
        .struct_instance => |si| {
            for (si.fields) |field| {
                if (findDanglingIsolatedType(field, isolation_frame, depth + 1)) |name| return name;
            }
            return null;
        },
        else => return null,
    }
}

/// After executing an isolated quotation, check that none of the output values
/// reference types from the isolation scope. Only called when the quotation has
/// a declared stack effect.
fn checkIsolationBoundary(ctx: *Context, effect: *const StackEffect, isolation_frame: *const TypeRegistryFrame) anyerror!void {
    const output_count = effect.concreteOutputCount();
    if (output_count == 0) return;
    if (isolation_frame.type_descriptors.count() == 0) return;

    var i: usize = 0;
    while (i < output_count) : (i += 1) {
        const val = ctx.stack.peekN(i) catch return;
        if (findDanglingIsolatedType(val, isolation_frame, 0)) |type_name| {
            const allocator = ctx.arena.allocator();
            ctx.pending_error_message = std.fmt.allocPrint(
                allocator,
                "value of type '{s}' cannot escape isolation scope",
                .{type_name},
            ) catch null;
            ctx.pending_error_hint = "types defined inside with-isolation are discarded on exit; the quotation's output values must not reference them";
            return error.TypeMismatch;
        }
    }
}

/// with-isolation ( quot -- ) - Execute quotation with isolated type registry,
/// dispatch tables, and protocol obligations. Only stack effects survive.
fn nativeWithIsolation(ctx: *Context) anyerror!void {
    const quot = try popQuotation(ctx);

    try ctx.pushTypeRegistryFrame();
    defer ctx.popTypeRegistryFrame();

    try ctx.pushDispatchFrame();
    defer ctx.popDispatchFrame();

    const saved_obligations = ctx.protocol_obligations;
    ctx.protocol_obligations = .{};
    defer {
        ctx.protocol_obligations.deinit(ctx.allocator);
        ctx.protocol_obligations = saved_obligations;
    }

    try ctx.executeQuotationWithFrame(quot);

    if (quot.effect) |effect| {
        const frames = ctx.type_registry_frames.items;
        if (frames.len > 0) {
            try checkIsolationBoundary(ctx, effect, &frames[frames.len - 1]);
        }
    }
}
