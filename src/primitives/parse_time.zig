const std = @import("std");
const Context = @import("../context.zig").Context;
const parser = @import("../parser.zig");
const tokenizer_mod = @import("../tokenizer.zig");
const Token = tokenizer_mod.Token;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "(", .stack_effect = "-- stack-effect", .doc = "Parse a stack effect declaration.", .func = nativeOpenParen, .parse_time = true },
    .{ .name = "parse-until", .stack_effect = "delimiter -- quotation", .doc = "Read tokens until delimiter, return as quotation.", .func = nativeParseUntil, .parse_time_only = true },
    .{ .name = "parse-tokens-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, return as string array.", .func = nativeParseTokensUntil, .parse_time_only = true },
    .{ .name = "parse-values-until", .stack_effect = "delimiter -- array", .doc = "Read tokens until delimiter, executing parse-time words. Return as array.", .func = nativeParseValuesUntil, .parse_time_only = true },
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

    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;

        const token = tok.text;
        if (std.mem.eql(u8, token, delimiter)) {
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
        try tokens.append(alloc, .{ .string = token_copy });
    }

    const result = try tokens.toOwnedSlice(alloc);
    return .{ .array = result };
}

/// Resolve a token string as a scalar literal value. Returns null if the token
/// is not a recognized scalar form. Checks in order: fixnum, bignum, float,
/// quoted string (with escape processing), trailing-colon symbol.
fn resolveScalarLiteral(alloc: std.mem.Allocator, arena_alloc: std.mem.Allocator, token: []const u8) std.mem.Allocator.Error!?Value {
    if (tokenizer_mod.parseInteger(token)) |n| {
        return .{ .fixnum = n };
    }

    if (tokenizer_mod.parseBigNum(arena_alloc, token)) |big| {
        return .{ .bignum = try value_mod.boxBigInt(arena_alloc, big) };
    }

    if (tokenizer_mod.parseFloat(token)) |f| {
        return .{ .float = f };
    }

    if (tokenizer_mod.parseString(token)) |s| {
        const s_copy = try parser.processEscapes(alloc, s);
        return .{ .string = s_copy };
    }

    if (token.len > 1 and token[token.len - 1] == ':') {
        const sym_copy = try alloc.dupe(u8, token[0 .. token.len - 1]);
        return .{ .symbol = sym_copy };
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
        const arr = parser.parseArray(alloc, tokenizer, ctx, tok.line) catch return error.OutOfMemory;
        return .{ .array = arr };
    }

    if (std.mem.eql(u8, token, "[")) {
        const quot = parser.parseQuotation(alloc, tokenizer, ctx, tok.line) catch return error.OutOfMemory;
        return .{ .quotation = quot };
    }

    return error.NotALiteral;
}

/// ( ( -- stack-effect ) - Parse a stack effect declaration from the tokenizer.
fn nativeOpenParen(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();
    const line = if (tokenizer.peeked) |p| p.line else 0;
    const effect = parser.parseStackEffect(alloc, tokenizer, ctx, line) catch return error.ParseError;
    try ctx.stack.push(.{ .stack_effect = effect });
}

/// parse-until ( delimiter -- quotation ) - Read tokens until delimiter, return as quotation
/// This is a parse-time primitive that reads from the active tokenizer.
pub fn nativeParseUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);

    const tokenizer = ctx.parse_tokenizer.?;

    const quot = parser.parseQuotationUntil(ctx.quotationAllocator(), tokenizer, ctx, delimiter, 0) catch return error.OutOfMemory;

    try ctx.stack.push(.{ .quotation = quot });
}

/// parse-tokens-until ( delimiter -- array ) - Read tokens until delimiter, return as string array
/// This is a parse-time primitive that reads raw tokens from the active tokenizer.
/// Unlike parse-until, this does not parse the tokens as instructions - it returns
/// them as literal strings, useful for syntax like `method{ type1 type2 }`.
pub fn nativeParseTokensUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);
    const result = try parseTokensUntilCore(ctx, delimiter, .raw);
    try ctx.stack.pushMoved(result);
}

/// parse-values-until ( delimiter -- array ) - Read tokens until delimiter, executing parse-time words
pub fn nativeParseValuesUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);
    const result = try parseTokensUntilCore(ctx, delimiter, .evaluate_parse_time);
    try ctx.stack.pushMoved(result);
}

/// parse-types-until ( delimiter -- array ) - Read tokens until delimiter, executing parse-time words.
/// Unknown tokens are errors.
fn nativeParseTypesUntil(ctx: *Context) anyerror!void {
    const delimiter = try popString(ctx);
    const result = try parseTokensUntilCore(ctx, delimiter, .evaluate_parse_time_strict);
    try ctx.stack.pushMoved(result);
}

/// parse-token ( -- string ) - Read one raw token from the tokenizer
fn nativeParseToken(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;
        const token_copy = try alloc.dupe(u8, tok.text);
        try ctx.stack.push(.{ .string = token_copy });
        return;
    }
    return error.ParseError;
}

/// peek-token ( -- string ) - Return the next token without consuming it
fn nativePeekToken(ctx: *Context) anyerror!void {
    const tokenizer = ctx.parse_tokenizer.?;
    const alloc = ctx.quotationAllocator();
    while (tokenizer.nextOrYield()) |tok| {
        if (isSkippable(tok.kind)) continue;
        tokenizer.peeked = tok;
        const token_copy = try alloc.dupe(u8, tok.text);
        try ctx.stack.push(.{ .string = token_copy });
        return;
    }
    return error.ParseError;
}

/// resolve-literal ( string -- value true | string false )
fn nativeResolveLiteral(ctx: *Context) anyerror!void {
    const token = try popString(ctx);
    const alloc = ctx.quotationAllocator();

    if (try resolveScalarLiteral(alloc, ctx.arena.allocator(), token)) |val| {
        try ctx.stack.push(val);
        try ctx.stack.push(.{ .boolean = true });
    } else {
        try ctx.stack.push(.{ .string = token });
        try ctx.stack.push(.{ .boolean = false });
    }
}

/// emit-call ( symbol -- ) - Request a call_word emission after parse-time word completes.
fn nativeEmitCall(ctx: *Context) anyerror!void {
    const name = switch (try ctx.stack.pop()) {
        .symbol => |s| s,
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

    try ctx.parse_time_deferred_emissions.append(ctx.allocator, .{ .call = name });
}

/// emit-body ( quotation -- ) - Splice the quotation's body inline after the
/// parse-time word completes.
fn nativeEmitBody(ctx: *Context) anyerror!void {
    const quot = try helpers.popQuotation(ctx);
    try ctx.parse_time_deferred_emissions.append(ctx.allocator, .{ .body = quot.instructions });
}

/// parse-literal ( -- value ) - Read the next literal from the tokenizer.
///
/// Three layers: scalar literals, structure openers, parse-time word execution.
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
            const arr = parser.parseArray(alloc, tokenizer, ctx, tok.line) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .array = arr });
            return;
        }

        if (std.mem.eql(u8, token, "[")) {
            const quot = parser.parseQuotation(alloc, tokenizer, ctx, tok.line) catch return error.OutOfMemory;
            try ctx.stack.push(.{ .quotation = quot });
            return;
        }

        if (ctx.lookupWord(token)) |word| {
            if (word.parse_time) {
                const pre_depth = ctx.stack.depth();
                switch (word.action) {
                    .native, .host_callback => try word.invoke(ctx),
                    .compound => |instrs| try ctx.executeQuotation(.{ .instructions = instrs }),
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

    helpers.setErrorContext(ctx, "parse-literal: no token available", .{});
    return error.TypeMismatch;
}
