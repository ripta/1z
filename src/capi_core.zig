const std = @import("std");
const Allocator = std.mem.Allocator;

const context_mod = @import("context.zig");
const Context = context_mod.Context;

const statement_mod = @import("statement.zig");
const StatementProcessor = statement_mod.StatementProcessor;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const container_backing = @import("container_backing.zig");

const dictionary_mod = @import("dictionary.zig");
const HostCallbackFn = dictionary_mod.HostCallbackFn;
const StackEffect = @import("stack_effect.zig").StackEffect;

// Type constants for value-type-introspection return values, shared by every C embedding root
// (hosted and wasm) so a type code means the same thing on both.
pub const ONEZ_TYPE_UNKNOWN: c_int = 0;
pub const ONEZ_TYPE_FIXNUM: c_int = 1;
pub const ONEZ_TYPE_FLOAT: c_int = 2;
pub const ONEZ_TYPE_BOOLEAN: c_int = 3;
pub const ONEZ_TYPE_STRING: c_int = 4;
pub const ONEZ_TYPE_SYMBOL: c_int = 5;
pub const ONEZ_TYPE_ARRAY: c_int = 6;
pub const ONEZ_TYPE_QUOTATION: c_int = 7;
pub const ONEZ_TYPE_HASH: c_int = 8;
pub const ONEZ_TYPE_VECTOR: c_int = 9;
pub const ONEZ_TYPE_BYTE_ARRAY: c_int = 10;
pub const ONEZ_TYPE_SET: c_int = 11;
pub const ONEZ_TYPE_MUTABLE_MAP: c_int = 12;
pub const ONEZ_TYPE_STREAM: c_int = 13;
pub const ONEZ_TYPE_RESOURCE: c_int = 14;
pub const ONEZ_TYPE_TAGGED: c_int = 15;
pub const ONEZ_TYPE_ITERATOR: c_int = 16;
pub const ONEZ_TYPE_TYPE_VAL: c_int = 17;
pub const ONEZ_TYPE_UNIT: c_int = 18;
pub const ONEZ_TYPE_STRUCT: c_int = 19;

pub fn valueTypeToInt(val: Value) c_int {
    return switch (val) {
        .fixnum => ONEZ_TYPE_FIXNUM,
        .float => ONEZ_TYPE_FLOAT,
        .boolean => ONEZ_TYPE_BOOLEAN,
        .string => ONEZ_TYPE_STRING,
        .symbol => ONEZ_TYPE_SYMBOL,
        .array => ONEZ_TYPE_ARRAY,
        .quotation => ONEZ_TYPE_QUOTATION,
        .hash => ONEZ_TYPE_HASH,
        .vector => ONEZ_TYPE_VECTOR,
        .byte_array => ONEZ_TYPE_BYTE_ARRAY,
        .set => ONEZ_TYPE_SET,
        .mutable_map => ONEZ_TYPE_MUTABLE_MAP,
        .stream => ONEZ_TYPE_STREAM,
        .resource => ONEZ_TYPE_RESOURCE,
        .tagged => ONEZ_TYPE_TAGGED,
        .iterator => ONEZ_TYPE_ITERATOR,
        .type_val => ONEZ_TYPE_TYPE_VAL,
        .unit => ONEZ_TYPE_UNIT,
        .struct_instance => ONEZ_TYPE_STRUCT,
        else => ONEZ_TYPE_UNKNOWN,
    };
}

/// Three-way (plus execution-failure) outcome of feeding source through a `StatementProcessor`,
/// shared by the hosted blob-eval loop and the wasm per-call incremental eval entry point.
pub const EvalOutcome = union(enum) {
    needs_more_input,
    complete,
    parse_error: anyerror,
    exec_error: anyerror,
};

/// Given an already-produced `StatementProcessor.Result`, execute a complete statement's
/// instructions (if any) and fold the outcome into `EvalOutcome`.
///
/// `do_reset` controls whether the processor's buffer is reset on completion: callers driving a
/// live per-line loop reset so the next line starts fresh; a final flush does not, since the
/// processor is about to be discarded.
fn executeStatementResult(
    ctx: *Context,
    processor: *StatementProcessor,
    result: StatementProcessor.Result,
    do_reset: bool,
) EvalOutcome {
    return switch (result) {
        .needs_more_input => .needs_more_input,
        .parse_error => |err| .{ .parse_error = err },
        .complete => |instrs| blk: {
            if (instrs.len > 0) {
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| break :blk .{ .exec_error = err };
            }
            if (do_reset) processor.reset();
            break :blk .complete;
        },
    };
}

/// Feed one line/chunk of source into `processor` and execute it if it completes a statement.
pub fn evalStep(ctx: *Context, processor: *StatementProcessor, alloc: Allocator, source: []const u8) EvalOutcome {
    return executeStatementResult(ctx, processor, processor.feedLine(alloc, source, ctx), true);
}

/// Force completion of any content still buffered in `processor` (no more input is coming) and
/// execute it if it completes a statement.
pub fn evalFlush(ctx: *Context, processor: *StatementProcessor, alloc: Allocator) EvalOutcome {
    return executeStatementResult(ctx, processor, processor.flush(alloc, ctx), false);
}

pub fn allocPrintZ(alloc: Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const str = try std.fmt.allocPrint(alloc, fmt, args);
    const buf = try alloc.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    alloc.free(str);
    return buf[0..str.len :0];
}

/// Format a captured runtime/parse error using whatever diagnostic detail `ctx` accumulated,
/// mirroring the message shape callers already surface via `onez_print_error`. Returns null only
/// on an allocation failure.
pub fn formatCapturedError(ctx: *Context, alloc: Allocator, err: anyerror) ?[:0]const u8 {
    ctx.finalizeErrorDetails(err);

    const details = ctx.error_details.items;
    if (details.len > 0) {
        const detail = details[0];
        // A host callback's custom message (set via onez_set_error) is folded into the innermost
        // detail's message by finalizeErrorDetails, so surface it the same way
        // onez_print_error does: append it when it carries more than the word name.
        if (detail.word_name == null or !std.mem.eql(u8, detail.message, detail.word_name.?)) {
            return allocPrintZ(
                alloc,
                "{s}:{d}: error '{s}' {s}",
                .{ detail.source, detail.line, detail.error_type, detail.message },
            ) catch null;
        }
        return allocPrintZ(
            alloc,
            "{s}:{d}: error '{s}'",
            .{ detail.source, detail.line, detail.error_type },
        ) catch null;
    }
    if (ctx.pending_error_message) |msg| {
        return allocPrintZ(alloc, "{s}", .{msg}) catch null;
    }
    return allocPrintZ(alloc, "{s}", .{@errorName(err)}) catch null;
}

pub fn pushInt(ctx: *Context, value: i64) !void {
    try ctx.stack.push(.{ .fixnum = value });
}

pub fn pushDouble(ctx: *Context, value: f64) !void {
    try ctx.stack.push(.{ .float = value });
}

pub fn pushBool(ctx: *Context, value: bool) !void {
    try ctx.stack.push(.{ .boolean = value });
}

pub fn pushString(ctx: *Context, data: []const u8) !void {
    const copy = try ctx.allocator.dupe(u8, data);
    const val = value_mod.ownedStringValue(ctx.allocator, copy) catch |err| {
        ctx.allocator.free(copy);
        return err;
    };
    ctx.stack.pushMoved(val) catch |err| {
        container_backing.releaseValue(val);
        return err;
    };
}

pub fn pushSymbol(ctx: *Context, data: []const u8) !void {
    const copy = try ctx.allocator.dupe(u8, data);
    const val = value_mod.ownedSymbolValue(ctx.allocator, copy) catch |err| {
        ctx.allocator.free(copy);
        return err;
    };
    ctx.stack.pushMoved(val) catch |err| {
        container_backing.releaseValue(val);
        return err;
    };
}

/// Push a value the caller already owns a box for, without retaining -- mirrors
/// `Stack.pushMoved`'s ownership-transfer contract.
pub fn pushBoxedValue(ctx: *Context, value: *const Value) !void {
    try ctx.stack.push(value.*);
}

/// Pop the top of the stack and box it onto `ctx`'s allocator, restoring the stack if boxing
/// fails so the pop stays atomic from the caller's view.
pub fn popValueBoxed(ctx: *Context) !*Value {
    const val = try ctx.stack.pop();
    return boxValue(ctx, val);
}

pub fn boxValue(ctx: *Context, val: Value) !*Value {
    const slot = ctx.quotationAllocator().create(Value) catch |err| {
        ctx.stack.pushMoved(val) catch {};
        return err;
    };
    slot.* = val;
    return slot;
}

/// Non-destructive box of the value at stack position `index` (0 = top).
pub fn peekBoxed(ctx: *Context, index: usize) !*Value {
    const val = try ctx.stack.peekN(index);
    const slot = try ctx.quotationAllocator().create(Value);
    slot.* = val;
    return slot;
}

/// Pop the top of the stack and require it to be a `.fixnum`. On a type mismatch, the popped
/// value is pushed back (so the stack is unaffected) and the mismatched value is written to
/// `mismatched_out` for the caller's error message; on `error.StackUnderflow` `mismatched_out`
/// is untouched.
pub fn popInt(ctx: *Context, mismatched_out: *Value) !i64 {
    const val = try ctx.stack.pop();
    switch (val) {
        .fixnum => |v| return v,
        else => {
            ctx.stack.pushMoved(val) catch {};
            mismatched_out.* = val;
            return error.TypeMismatch;
        },
    }
}

pub fn popDouble(ctx: *Context, mismatched_out: *Value) !f64 {
    const val = try ctx.stack.pop();
    switch (val) {
        .float => |v| return v,
        else => {
            ctx.stack.pushMoved(val) catch {};
            mismatched_out.* = val;
            return error.TypeMismatch;
        },
    }
}

pub fn popBool(ctx: *Context, mismatched_out: *Value) !bool {
    const val = try ctx.stack.pop();
    switch (val) {
        .boolean => |v| return v,
        else => {
            ctx.stack.pushMoved(val) catch {};
            mismatched_out.* = val;
            return error.TypeMismatch;
        },
    }
}

/// Pop the top of the stack and require it to be a `.string`. The returned bytes are duped
/// onto the context arena, so the C caller keeps today's until-teardown lifetime regardless
/// of the popped value's backing. The popped reference is released here.
pub fn popString(ctx: *Context, mismatched_out: *Value) ![]const u8 {
    const val = try ctx.stack.pop();
    switch (val) {
        .string => |s| {
            const copy = ctx.quotationAllocator().dupe(u8, s.bytes) catch |err| {
                ctx.stack.pushMoved(val) catch {};
                return err;
            };
            container_backing.releaseValue(val);
            return copy;
        },
        else => {
            ctx.stack.pushMoved(val) catch {};
            mismatched_out.* = val;
            return error.TypeMismatch;
        },
    }
}

/// Construct a host-callback word definition and register it under `name` (already duped onto
/// the caller's allocator). Shared so a host-registered word looks identical regardless of which
/// embedding root defined it.
pub fn defineHostWord(
    ctx: *Context,
    name_copy: []const u8,
    effect: ?*const StackEffect,
    callback: HostCallbackFn,
    callback_handle: ?*anyopaque,
    user_data: ?*anyopaque,
) !void {
    try ctx.defineWord(name_copy, .{
        .name = name_copy,
        .stack_effect = effect,
        .action = .{ .host_callback = .{
            .handle = callback_handle,
            .callback = callback,
            .user_data = user_data,
        } },
    });
}
