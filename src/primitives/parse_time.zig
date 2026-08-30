const std = @import("std");
const Context = @import("../context.zig").Context;
const parser = @import("../parser.zig");
const tokenizer_mod = @import("../tokenizer.zig");
const Token = tokenizer_mod.Token;
const value_mod = @import("../value.zig");
const container_backing = @import("../container_backing.zig");
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const markers = @import("markers.zig");
const Primitive = @import("types.zig").Primitive;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "(", .stack_effect = "-- stack-effect", .doc = "Parse a stack effect declaration.", .func = nativeOpenParen, .parse_time = true },
    .{ .name = "parse-until", .stack_effect = "delimiter -- quotation", .doc = "Read tokens until delimiter, return as quotation.", .func = nativeParseUntil, .parse_time_only = true },
    .{ .name = "parse-tokens-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, return as string array.", .func = nativeParseTokensUntil, .parse_time_only = true },
    .{ .name = "parse-values-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, executing parse-time words. Return as array.", .func = nativeParseValuesUntil, .parse_time_only = true },
    .{ .name = "bind-until", .stack_effect = "delimiter -- placeholder", .doc = "Read a bind{ ... } body until delimiter, execute it at parse time, and package the resulting type values into a binding placeholder array for the enclosing field/variant parser.", .func = nativeBindUntil, .parse_time_only = true },
    .{ .name = "parse-types-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, executing parse-time words. Unknown tokens are errors.", .func = nativeParseTypesUntil, .parse_time_only = true },
    .{ .name = "parse-token", .stack_effect = "-- string", .doc = "Read one raw token from the tokenizer, skipping comments and whitespace.", .func = nativeParseToken, .parse_time_only = true },
    .{ .name = "peek-token", .stack_effect = "-- string", .doc = "Return the next token without consuming it. Repeated calls return the same token until parse-token or another consuming primitive advances past it.", .func = nativePeekToken, .parse_time_only = true },
    .{ .name = "parse-literal", .stack_effect = "-- value", .doc = "Read the next literal value from the tokenizer.", .func = nativeParseLiteral, .parse_time_only = true },
    .{ .name = "resolve-literal", .stack_effect = "string -- value ?", .doc = "Resolve a string as a scalar literal.", .func = nativeResolveLiteral },
    .{ .name = "emit-call", .stack_effect = "symbol --", .doc = "Request a call_word emission for the named word after the current parse-time word completes.", .func = nativeEmitCall, .parse_time_only = true },
    .{ .name = "emit-body", .stack_effect = "quotation --", .doc = "Splice the quotation's body (its instructions) inline into the current parse stream after the calling word's stack results.", .func = nativeEmitBody, .parse_time_only = true },
};

fn isSkippable(kind: Token.Kind) bool {
    return kind == .comment or kind == .doc_comment or kind == .newline;
}

const ParseMode = enum { raw, evaluate_parse_time, evaluate_parse_time_strict };

fn parseTokensUntilCore(ctx: *Context, delimiter: []const u8, mode: ParseMode) !Value {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();

    var tokens = std.ArrayListUnmanaged(Value){};
    defer tokens.deinit(alloc);
    // The loop transfers ownership of popped values into `tokens`. On the
    // happy path those refs move on into the returned `.array`. On error
    // the partial list must release each owning ref so containers don't
    // leak.
    errdefer for (tokens.items) |item| @import("../container_backing.zig").releaseValue(item);

    // Distinguishes "found the delimiter" from "the tokenizer ran out of
    // buffered input before the delimiter appeared." Without this, a
    // coroutine-free scan (StatementProcessor.tryParseDirect, freestanding/wasm
    // builds) silently treats a not-yet-complete statement -- e.g. `use
    // "modname"` before its terminating `;` is typed -- as if the delimiter had
    // been found, running the caller's side effects and returning a truncated
    // result instead of signaling incompleteness.
    var found_delimiter = false;

    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, delimiter)) {
            found_delimiter = true;
            break;
        }

        if (mode == .evaluate_parse_time or mode == .evaluate_parse_time_strict) {
            if (try parser.maybeParseConstraintExpression(alloc, tokenizer, ctx, token)) |constraint_val| {
                try tokens.append(alloc, constraint_val);
                continue;
            }

            if (tryResolveLiteral(ctx, alloc, tokenizer, tok)) |val| {
                try tokens.append(alloc, val);
                continue;
            } else |err| switch (err) {
                error.NotALiteral => {},
                else => return err,
            }

            if (ctx.lookupWord(token)) |word| {
                if (word.parse_time) {
                    const pre_depth = ctx.stack.depth();
                    switch (word.action) {
                        .native, .host_callback => try word.invoke(ctx),
                        .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
                        .literal => |v| try ctx.stack.push(v),
                    }
                    const post_depth = ctx.stack.depth();
                    if (post_depth > pre_depth) {
                        var i: usize = 0;
                        const num_results = post_depth - pre_depth;
                        while (i < num_results) : (i += 1) {
                            const val = try ctx.stack.pop();
                            try tokens.append(alloc, val);
                        }
                        // Reverse the results so they appear in stack order
                        const start = tokens.items.len - num_results;
                        std.mem.reverse(Value, tokens.items[start..]);
                    }
                    continue;
                }
            }
        }

        if (mode == .evaluate_parse_time_strict) {
            helpers.setErrorContext(ctx, "'{s}' is not a known type", .{token});
            return error.TypeMismatch;
        }

        const token_copy = try alloc.dupe(u8, token);
        try tokens.append(alloc, value_mod.stringValue(token_copy));
    }

    if (!found_delimiter) return error.UnterminatedTokenScan;

    const result = try tokens.toOwnedSlice(alloc);
    return .{ .array = try value_mod.Array.fromOwnedSlice(alloc, result) };
}

/// Resolve a token string as a scalar literal value. Returns null if the token is not a
/// recognized scalar form.
fn resolveScalarLiteral(alloc: std.mem.Allocator, arena_alloc: std.mem.Allocator, token: []const u8) std.mem.Allocator.Error!?Value {
    if (tokenizer_mod.parseInteger(token)) |n| {
        return .{ .fixnum = n };
    }

    if (tokenizer_mod.parseBigNum(arena_alloc, token)) |big| {
        return try value_mod.bignumValue(arena_alloc, big);
    }

    if (tokenizer_mod.parseFloat(token)) |f| {
        return .{ .float = f };
    }

    if (tokenizer_mod.parseString(token)) |s| {
        const s_copy = try parser.processEscapes(alloc, s);
        return value_mod.stringValue(s_copy);
    }

    if (token.len > 1 and token[token.len - 1] == ':') {
        const sym_copy = try alloc.dupe(u8, token[0 .. token.len - 1]);
        return value_mod.symbolValue(sym_copy);
    }

    return null;
}

/// Try to resolve a token as a literal value. Returns NotALiteral if the token
/// is not a recognized literal form, allowing the caller to fall through.
fn tryResolveLiteral(ctx: *Context, alloc: std.mem.Allocator, tokenizer: *tokenizer_mod.Tokenizer, tok: Token) !Value {
    const token = tok.text;

    if (try resolveScalarLiteral(alloc, ctx.arena.allocator(), token)) |val| {
        return val;
    }

    if (std.mem.eql(u8, token, "{")) {
        const arr = try parser.parseArray(alloc, tokenizer, ctx, tok.line);
        return .{ .array = arr };
    }

    if (std.mem.eql(u8, token, "[")) {
        const quot = try parser.parseQuotation(alloc, tokenizer, ctx, tok.line);
        return .{ .quotation = quot };
    }

    return error.NotALiteral;
}

/// ( ( -- stack-effect )
fn nativeOpenParen(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();
    const line = if (tokenizer.peeked) |p| p.line else 0;
    const effect = parser.parseStackEffect(alloc, tokenizer, ctx, line) catch return error.ParseError;
    try ctx.stack.push(.{ .stack_effect = effect });
}

/// parse-until ( delimiter -- quotation )
pub fn nativeParseUntil(ctx: *Context) anyerror!void {
    const delimiter_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = delimiter_pay });
    const delimiter = delimiter_pay.bytes;

    const tokenizer = ctx.parse_tokenizer.?;

    const quot = try parser.parseQuotationUntil(ctx.quotationAllocator(), tokenizer, ctx, delimiter, 0);

    try ctx.stack.push(.{ .quotation = quot });
}

/// bind-until ( delimiter -- placeholder )
///
/// The base type is not on the stack: it was already drained into the enclosing
/// definition's `parse-values-until` collection array before `bind{` ran. The
/// placeholder carries only the body's parameters; the field/variant parser
/// combines it with the adjacent base.
fn nativeBindUntil(ctx: *Context) anyerror!void {
    const delimiter_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = delimiter_pay });
    const delimiter = delimiter_pay.bytes;
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();

    const quot = try parser.parseQuotationUntil(alloc, tokenizer, ctx, delimiter, 0);

    // The body runs with full data-stack access, so permissive contents
    // (`choose`, `if`, arithmetic) work. Each value it leaves is one positional
    // parameter: a `.symbol` for `T:`, or a `.type_val` for a concrete/computed type.
    const pre = ctx.stack.depth();
    try ctx.executeQuotation(quot);
    const post = ctx.stack.depth();
    const n = post - pre;

    const placeholder = try alloc.alloc(Value, n + 1);
    placeholder[0] = .{ .marker = @constCast(&markers.bind_placeholder_marker) };
    // The stack holds the body's results in reverse source order; fill the tail
    // so `placeholder[1]` is the first-pushed (leftmost) value, position 0.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        placeholder[n - i] = try ctx.stack.pop();
    }
    // The popped references transfer into the placeholder array wholesale.
    try helpers.pushAdoptedArray(ctx, alloc, placeholder);
}

/// parse-tokens-until ( delimiter -- array )
///
/// Unlike parse-until, this does not parse tokens as instructions -- it returns them as literal
/// strings, useful for syntax like `method{ type1 type2 }`.
pub fn nativeParseTokensUntil(ctx: *Context) anyerror!void {
    const delimiter_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = delimiter_pay });
    const result = try parseTokensUntilCore(ctx, delimiter_pay.bytes, .raw);
    try ctx.stack.pushMoved(result);
}

/// parse-values-until ( delimiter -- array )
pub fn nativeParseValuesUntil(ctx: *Context) anyerror!void {
    const delimiter_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = delimiter_pay });
    const result = try parseTokensUntilCore(ctx, delimiter_pay.bytes, .evaluate_parse_time);
    try ctx.stack.pushMoved(result);
}

/// parse-types-until ( delimiter -- array )
fn nativeParseTypesUntil(ctx: *Context) anyerror!void {
    const delimiter_pay = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = delimiter_pay });
    const result = try parseTokensUntilCore(ctx, delimiter_pay.bytes, .evaluate_parse_time_strict);
    try ctx.stack.pushMoved(result);
}

/// parse-token ( -- string )
fn nativeParseToken(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;
        const token_copy = try alloc.dupe(u8, tok.text);
        try ctx.stack.push(value_mod.stringValue(token_copy));
        return;
    }
    return error.UnterminatedTokenScan;
}

/// peek-token ( -- string )
fn nativePeekToken(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;
        tokenizer.peeked = tok;
        const token_copy = try alloc.dupe(u8, tok.text);
        try ctx.stack.push(value_mod.stringValue(token_copy));
        return;
    }
    return error.UnterminatedTokenScan;
}

/// resolve-literal ( string -- value true | string false )
fn nativeResolveLiteral(ctx: *Context) anyerror!void {
    const token = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = token });
    const alloc = ctx.quotationAllocator();

    if (try resolveScalarLiteral(alloc, ctx.arena.allocator(), token.bytes)) |val| {
        try ctx.stack.push(val);
        try ctx.stack.push(.{ .boolean = true });
    } else {
        try ctx.stack.push(.{ .string = token });
        try ctx.stack.push(.{ .boolean = false });
    }
}

/// emit-call ( symbol -- )
fn nativeEmitCall(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    defer container_backing.releaseValue(val);
    const name = switch (val) {
        .symbol => |s| s.bytes,
        else => |v| {
            helpers.setTypeMismatchError(ctx, "symbol", v);
            return error.TypeMismatch;
        },
    };

    if (ctx.lookupWord(name)) |word| {
        if (word.parse_time_only) {
            helpers.setErrorContext(ctx, "cannot emit-call parse-time-only word '{s}'", .{name});
            return error.ParseError;
        }
    }

    // The deferred emission outlives the popped value.
    try ctx.parse_time_deferred_emissions.append(ctx.allocator, .{ .call = try ctx.quotationAllocator().dupe(u8, name) });
}

/// emit-body ( quotation -- )
fn nativeEmitBody(ctx: *Context) anyerror!void {
    // The body escapes into the deferred-emission list.
    const pc = try helpers.popQuotation(ctx);
    var adopted = false;
    errdefer if (!adopted) pc.release();

    // The splice copies these instructions into the enclosing body, which is registered for
    // container-literal release in its own right. A closure body's literals are owned by the
    // closure, which `adoptForTeardown` parks for the context's lifetime, so the copy
    // is a second owner and needs its own reference.
    //
    // A plain quotation owner needs no retain: its body is parsed instruction memory whose
    // literals already carry exactly one registered release covering the splice.
    const retained = pc.owner == .closure;
    if (retained) container_backing.retainInstructionsContainerLiterals(pc.quot.instructions);
    errdefer if (retained) container_backing.releaseInstructionsContainerLiterals(pc.quot.instructions);

    // Adopt before queueing. Dropping the last reference to a closure owner frees the body, so
    // an emission recorded first would be left pointing into freed memory if the adoption failed.
    try pc.adoptForTeardown(ctx);
    adopted = true;

    try ctx.parse_time_deferred_emissions.append(ctx.allocator, .{ .body = .{
        .instructions = pc.quot.instructions,
        .retained_literals = retained,
    } });
}

/// parse-literal ( -- value )
pub fn nativeParseLiteral(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;

        const token = tok.text;

        if (try resolveScalarLiteral(alloc, ctx.arena.allocator(), token)) |val| {
            try ctx.stack.push(val);
            return;
        }

        if (std.mem.eql(u8, token, "{")) {
            const arr = try parser.parseArray(alloc, tokenizer, ctx, tok.line);
            try ctx.stack.push(.{ .array = arr });
            return;
        }

        if (std.mem.eql(u8, token, "[")) {
            const quot = try parser.parseQuotation(alloc, tokenizer, ctx, tok.line);
            try ctx.stack.push(.{ .quotation = quot });
            return;
        }

        if (ctx.lookupWord(token)) |word| {
            if (word.parse_time) {
                const pre_depth = ctx.stack.depth();
                switch (word.action) {
                    .native, .host_callback => try word.invoke(ctx),
                    .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
                    .literal => |v| try ctx.stack.push(v),
                }
                const post_depth = ctx.stack.depth();
                if (post_depth > pre_depth) return;
                helpers.setErrorContext(ctx, "parse-literal: parse-time word '{s}' did not produce a value", .{token});
                return error.TypeMismatch;
            }
        }

        helpers.setErrorContext(ctx, "parse-literal: not a recognized literal: {s}", .{token});
        return error.TypeMismatch;
    }

    return error.UnterminatedTokenScan;
}
