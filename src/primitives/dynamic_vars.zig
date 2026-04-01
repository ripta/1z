const std = @import("std");
const Context = @import("../context.zig").Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Parameter = value_mod.Parameter;
const parser = @import("../parser.zig");
const tokenizer_mod = @import("../tokenizer.zig");

const Primitive = @import("types.zig").Primitive;
const helpers = @import("helpers.zig");

const popQuotation = helpers.popQuotation;
const popSymbol = helpers.popSymbol;

pub const primitives = [_]Primitive{
    .{ .name = "parse-quotation", .stack_effect = "-- quotation", .func = nativeParseQuotation },
    .{ .name = "parse-literal", .stack_effect = "-- value", .func = nativeParseLiteral },
    .{ .name = "make-parameter", .stack_effect = "name: quot -- param", .func = nativeMakeParameter },
    .{ .name = "get", .stack_effect = "param -- value", .func = nativeGet },
    .{ .name = "with-parameter", .stack_effect = "value param quot --", .func = nativeWithParameter },
};

// =============================================================================
// Parse-time primitives
// =============================================================================

/// parse-quotation ( -- quotation ) - Read the next [ ... ] block from the tokenizer
/// Can only be called during parse-time execution (when tokenizer is available)
pub fn nativeParseQuotation(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;

    // Skip whitespace/comments until we find '['
    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .doc_comment or tok.kind == .newline) continue;

        if (!std.mem.eql(u8, tok.text, "[")) {
            // Expected '[' but got something else
            return error.TypeMismatch;
        }

        // Found '[', now parse the quotation body
        const quot = parser.parseQuotation(ctx.quotationAllocator(), tokenizer, ctx) catch return error.OutOfMemory;
        try ctx.stack.push(.{ .quotation = quot });
        return;
    }

    // Unexpected end of input
    return error.TypeMismatch;
}

/// parse-literal ( -- value ) - Read the next literal from the tokenizer
pub fn nativeParseLiteral(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer orelse return error.NoTokenizerAvailable;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.next()) |tok| {
        if (tok.kind == .comment or tok.kind == .doc_comment or tok.kind == .newline) continue;

        const token = tok.text;

        if (std.mem.eql(u8, token, "{")) {
            const arr = parser.parseArray(alloc, tokenizer, ctx) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .array = arr });
            return;
        }

        if (std.mem.eql(u8, token, "[")) {
            const quot = parser.parseQuotation(alloc, tokenizer, ctx) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .quotation = quot });
            return;
        }

        if (tokenizer_mod.parseString(token)) |s| {
            const s_copy = parser.processEscapes(alloc, s) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .string = s_copy });
            return;
        }

        if (token.len > 1 and token[token.len - 1] == ':') {
            const sym_copy = alloc.dupe(u8, token[0 .. token.len - 1]) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .symbol = sym_copy });
            return;
        }

        if (tokenizer_mod.parseInteger(token)) |n| {
            try ctx.stack.push(.{ .integer = n });
            return;
        }

        return error.TypeMismatch;
    }

    return error.TypeMismatch;
}

// =============================================================================
// Runtime primitives
// =============================================================================

/// make-parameter ( name: quot -- param ) - Create a parameter with the given name and default quotation
pub fn nativeMakeParameter(ctx: *Context) anyerror!void {
    const default_quot = try popQuotation(ctx);
    const name = try popSymbol(ctx);

    const alloc = ctx.quotationAllocator();
    const param = alloc.create(Parameter) catch return error.OutOfMemory;
    param.* = .{
        .name = alloc.dupe(u8, name) catch return error.OutOfMemory,
        .default_quotation = default_quot,
    };

    try ctx.stack.push(.{ .parameter = param });
}

/// get ( param -- value ) - Get the current value of a parameter
/// Searches environment frames from top to bottom; if not found, evaluates default quotation
pub fn nativeGet(ctx: *Context) anyerror!void {
    const param_val = try ctx.stack.pop();
    const param = switch (param_val) {
        .parameter => |p| p,
        else => return error.TypeMismatch,
    };

    // Search frames from top (innermost) to bottom (outermost)
    if (ctx.getParameterBinding(param.name)) |bound_value| {
        try ctx.stack.push(bound_value);
    } else {
        // No binding found - evaluate default quotation
        // The result is left on the stack by the quotation
        try ctx.executeQuotation(param.default_quotation);
    }
}

/// with-parameter ( value param quot -- ... ) - Execute quotation with parameter temporarily bound
/// The parameter binding is restored even if the quotation throws an error
pub fn nativeWithParameter(ctx: *Context) anyerror!void {
    const body_quot = try popQuotation(ctx);
    const param_val = try ctx.stack.pop();
    const param = switch (param_val) {
        .parameter => |p| p,
        else => return error.TypeMismatch,
    };
    const new_value = try ctx.stack.pop();

    // Push new frame with binding
    try ctx.pushParameterFrame();
    try ctx.setParameterInTopFrame(param.name, new_value);

    // Execute body with cleanup (pops frame even on error)
    const result = ctx.executeQuotationWithFrame(body_quot);
    ctx.popParameterFrame();
    try result;
}
